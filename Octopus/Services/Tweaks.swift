import Foundation
import Observation

/// Réglage caché de macOS, stocké dans les préférences (`defaults`).
struct Tweak: Identifiable {
    enum Kind {
        /// Case à cocher. `inverted` : la case cochée écrit `false` (« Ne pas… »).
        case toggle(defaultValue: Bool, inverted: Bool = false)
        /// Choix dans une liste de valeurs texte.
        case choice([(label: String, value: String)], defaultValue: String)
        /// Nombre décimal (délais, durées d'animation).
        case number(defaultValue: Double, range: ClosedRange<Double>, step: Double, unit: String)
        /// Dossier (chemin).
        case folder(defaultValue: String)
    }

    /// App à relancer pour que le réglage prenne effet.
    enum Relaunch: String {
        case finder = "Finder"
        case dock = "Dock"
        case systemUIServer = "SystemUIServer"
        case none = ""
    }

    let id: String
    let title: String
    var detail: String? = nil
    /// Domaine des préférences (« com.apple.finder ») ; `NSGlobalDomain` pour les réglages globaux.
    let domain: String
    let key: String
    let kind: Kind
    var relaunch: Relaunch = .none
}

struct TweakGroup: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tweaks: [Tweak]
}

/// Lit et écrit les réglages cachés, puis relance l'app concernée.
@MainActor
@Observable
final class TweaksStore {
    /// Valeur actuelle de chaque réglage, par identifiant.
    private(set) var values: [String: Any] = [:]
    private(set) var message: String?

    let groups = TweaksStore.catalog

    func reload() {
        var found: [String: Any] = [:]
        for tweak in groups.flatMap(\.tweaks) {
            let domain = tweak.domain == "NSGlobalDomain" ? kCFPreferencesAnyApplication : tweak.domain as CFString
            CFPreferencesAppSynchronize(domain)
            if let value = CFPreferencesCopyAppValue(tweak.key as CFString, domain) {
                found[tweak.id] = value
            }
        }
        values = found
    }

    // MARK: - Valeurs pour l'interface

    func bool(_ tweak: Tweak) -> Bool {
        guard case .toggle(let defaultValue, let inverted) = tweak.kind else { return false }
        let stored = (values[tweak.id] as? Bool) ?? (values[tweak.id] as? NSNumber)?.boolValue ?? defaultValue
        return inverted ? !stored : stored
    }

    func string(_ tweak: Tweak) -> String {
        switch tweak.kind {
        case .choice(_, let defaultValue): return values[tweak.id] as? String ?? defaultValue
        case .folder(let defaultValue): return values[tweak.id] as? String ?? defaultValue
        default: return ""
        }
    }

    func number(_ tweak: Tweak) -> Double {
        guard case .number(let defaultValue, _, _, _) = tweak.kind else { return 0 }
        return (values[tweak.id] as? NSNumber)?.doubleValue ?? defaultValue
    }

    // MARK: - Écriture

    func set(_ tweak: Tweak, bool: Bool) async {
        guard case .toggle(_, let inverted) = tweak.kind else { return }
        let stored = inverted ? !bool : bool
        await write(tweak, ["-bool", stored ? "true" : "false"])
    }

    func set(_ tweak: Tweak, string: String) async {
        await write(tweak, ["-string", string])
    }

    func set(_ tweak: Tweak, number: Double) async {
        await write(tweak, ["-float", String(number)])
    }

    /// Supprime la clé : macOS reprend son comportement par défaut.
    func reset(_ tweak: Tweak) async {
        _ = await SystemCommand.run("/usr/bin/defaults", ["delete", tweak.domain, tweak.key])
        await finish(tweak)
    }

    private func write(_ tweak: Tweak, _ value: [String]) async {
        let result = await SystemCommand.run("/usr/bin/defaults", ["write", tweak.domain, tweak.key] + value)
        guard result.succeeded else {
            message = String(localized: "Échec : ") + result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        await finish(tweak)
    }

    private func finish(_ tweak: Tweak) async {
        if tweak.relaunch != .none {
            _ = await SystemCommand.run("/usr/bin/killall", [tweak.relaunch.rawValue])
            message = String(localized: "« \(tweak.title) » appliqué (\(tweak.relaunch.rawValue) relancé).")
        } else {
            message = String(localized: "« \(tweak.title) » appliqué. Certaines apps doivent être relancées pour en tenir compte.")
        }
        reload()
    }

    // MARK: - Maintenance

    enum Maintenance: String, CaseIterable, Identifiable {
        case relaunchFinder, relaunchDock, launchServices, spotlight, purgeMemory

        var id: Self { self }

        var title: String {
            switch self {
            case .relaunchFinder: String(localized: "Relancer le Finder")
            case .relaunchDock: String(localized: "Relancer le Dock")
            case .launchServices: String(localized: "Reconstruire « Ouvrir avec »")
            case .spotlight: String(localized: "Réindexer Spotlight")
            case .purgeMemory: String(localized: "Libérer la mémoire inactive")
            }
        }

        var detail: String {
            switch self {
            case .relaunchFinder: String(localized: "Quand le Finder ne se rafraîchit plus ou se fige.")
            case .relaunchDock: String(localized: "Quand le Dock ou Mission Control se comportent bizarrement.")
            case .launchServices: String(localized: "Supprime les doublons et les apps disparues du menu « Ouvrir avec » et de « Choisir une app ».")
            case .spotlight: String(localized: "Efface puis reconstruit l'index du disque système. La recherche est incomplète pendant quelques dizaines de minutes.")
            case .purgeMemory: String(localized: "Vide les caches disque en mémoire (purge). Rarement utile : macOS les réutilise de lui-même.")
            }
        }

        var symbol: String {
            switch self {
            case .relaunchFinder: "folder"
            case .relaunchDock: "dock.rectangle"
            case .launchServices: "arrow.up.forward.app"
            case .spotlight: "magnifyingglass"
            case .purgeMemory: "memorychip"
            }
        }

        var needsAdmin: Bool { self == .spotlight || self == .purgeMemory }

        var command: String {
            switch self {
            case .relaunchFinder: "/usr/bin/killall Finder"
            case .relaunchDock: "/usr/bin/killall Dock"
            case .launchServices:
                "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain system -domain user"
            case .spotlight: "/usr/bin/mdutil -E /"
            case .purgeMemory: "/usr/sbin/purge"
            }
        }
    }

    func run(_ action: Maintenance) async {
        do {
            if action.needsAdmin {
                _ = try await PrivilegedShell.run(action.command)
            } else {
                let result = await SystemCommand.run("/bin/sh", ["-c", action.command])
                guard result.succeeded else { throw PrivilegedShell.Failure.failed(result.output) }
            }
            message = String(localized: "« \(action.title) » : terminé.")
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Catalogue

    static let catalog: [TweakGroup] = [
        TweakGroup(id: "finder", title: "Finder", symbol: "folder", tweaks: [
            Tweak(id: "hidden", title: String(localized: "Afficher les fichiers cachés"), detail: String(localized: "Raccourci dans le Finder : ⌘⇧."),
                  domain: "com.apple.finder", key: "AppleShowAllFiles", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "extensions", title: String(localized: "Afficher toutes les extensions de fichiers"),
                  domain: "NSGlobalDomain", key: "AppleShowAllExtensions", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "pathbar", title: String(localized: "Afficher la barre du chemin"),
                  domain: "com.apple.finder", key: "ShowPathbar", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "statusbar", title: String(localized: "Afficher la barre d'état"),
                  domain: "com.apple.finder", key: "ShowStatusBar", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "posixtitle", title: String(localized: "Chemin complet dans le titre des fenêtres"),
                  domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "foldersfirst", title: String(localized: "Dossiers en premier dans les listes"),
                  domain: "com.apple.finder", key: "_FXSortFoldersFirst", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "extwarning", title: String(localized: "Avertir quand on change une extension"),
                  domain: "com.apple.finder", key: "FXEnableExtensionChangeWarning", kind: .toggle(defaultValue: true), relaunch: .finder),
        ]),
        TweakGroup(id: "dsstore", title: "Fichiers .DS_Store", symbol: "doc.badge.gearshape", tweaks: [
            Tweak(id: "dsnetwork", title: String(localized: "Ne pas en créer sur les volumes réseau"),
                  detail: String(localized: "Évite d'encombrer les partages du NAS avec des fichiers .DS_Store."),
                  domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", kind: .toggle(defaultValue: false), relaunch: .finder),
            Tweak(id: "dsusb", title: String(localized: "Ne pas en créer sur les disques USB"),
                  domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", kind: .toggle(defaultValue: false), relaunch: .finder),
        ]),
        TweakGroup(id: "screenshots", title: String(localized: "Captures d'écran"), symbol: "camera.viewfinder", tweaks: [
            Tweak(id: "shotformat", title: String(localized: "Format"),
                  domain: "com.apple.screencapture", key: "type",
                  kind: .choice([("PNG", "png"), ("JPEG", "jpg"), ("HEIC", "heic"), ("PDF", "pdf"), ("TIFF", "tiff")], defaultValue: "png"),
                  relaunch: .systemUIServer),
            Tweak(id: "shotlocation", title: String(localized: "Dossier d'enregistrement"),
                  domain: "com.apple.screencapture", key: "location",
                  kind: .folder(defaultValue: NSHomeDirectory() + "/Desktop"), relaunch: .systemUIServer),
            Tweak(id: "shotshadow", title: String(localized: "Ombre autour des fenêtres capturées"),
                  domain: "com.apple.screencapture", key: "disable-shadow",
                  kind: .toggle(defaultValue: false, inverted: true), relaunch: .systemUIServer),
            Tweak(id: "shotdate", title: String(localized: "Date et heure dans le nom du fichier"),
                  domain: "com.apple.screencapture", key: "include-date", kind: .toggle(defaultValue: true), relaunch: .systemUIServer),
        ]),
        TweakGroup(id: "dock", title: "Dock", symbol: "dock.rectangle", tweaks: [
            Tweak(id: "dockdelay", title: String(localized: "Délai avant l'apparition (masquage auto)"),
                  detail: String(localized: "0 : le Dock apparaît dès que la souris touche le bord."),
                  domain: "com.apple.dock", key: "autohide-delay",
                  kind: .number(defaultValue: 0.5, range: 0...2, step: 0.1, unit: "s"), relaunch: .dock),
            Tweak(id: "dockanim", title: String(localized: "Durée de l'animation (masquage auto)"),
                  domain: "com.apple.dock", key: "autohide-time-modifier",
                  kind: .number(defaultValue: 0.5, range: 0...2, step: 0.1, unit: "s"), relaunch: .dock),
            Tweak(id: "dockrecents", title: String(localized: "Afficher les apps récentes"),
                  domain: "com.apple.dock", key: "show-recents", kind: .toggle(defaultValue: true), relaunch: .dock),
            Tweak(id: "dockstatic", title: String(localized: "N'afficher que les apps ouvertes"),
                  domain: "com.apple.dock", key: "static-only", kind: .toggle(defaultValue: false), relaunch: .dock),
            Tweak(id: "dockhidden", title: String(localized: "Icônes translucides pour les apps masquées"),
                  domain: "com.apple.dock", key: "showhidden", kind: .toggle(defaultValue: false), relaunch: .dock),
        ]),
        TweakGroup(id: "misc", title: String(localized: "Divers"), symbol: "slider.horizontal.3", tweaks: [
            Tweak(id: "savepanel", title: String(localized: "Fenêtres d'enregistrement développées par défaut"),
                  domain: "NSGlobalDomain", key: "NSNavPanelExpandedStateForSaveMode", kind: .toggle(defaultValue: false)),
            Tweak(id: "printpanel", title: String(localized: "Fenêtres d'impression développées par défaut"),
                  domain: "NSGlobalDomain", key: "PMPrintingExpandedStateForPrint", kind: .toggle(defaultValue: false)),
            Tweak(id: "textedit", title: String(localized: "TextEdit : texte brut par défaut"),
                  domain: "com.apple.TextEdit", key: "RichText", kind: .toggle(defaultValue: true, inverted: true)),
            Tweak(id: "presshold", title: String(localized: "Maintenir une touche pour la répéter (au lieu des accents)"),
                  detail: String(localized: "Pris en compte par les apps relancées après le changement."),
                  domain: "NSGlobalDomain", key: "ApplePressAndHoldEnabled", kind: .toggle(defaultValue: true, inverted: true)),
        ]),
    ]
}
