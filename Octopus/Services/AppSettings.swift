import AppKit
import Foundation

/// Clés des préférences d'Octopus.
enum Prefs {
    static let appearance = "appearance"
    /// L'utilisateur a choisi de ne plus voir la fenêtre des autorisations au lancement.
    static let skipPermissionsPrompt = "skipPermissionsPrompt"
    /// Paquets Homebrew exclus des mises à jour (identifiants « type:nom »).
    static let brewExcluded = "brewExcludedPackages"
}

/// Apparence de l'app : celle de macOS, ou forcée en clair / sombre (comme dans Flux).
enum AppAppearance {
    static let system = "system"
    static let light = "light"
    static let dark = "dark"

    @MainActor
    static func apply(_ value: String? = nil) {
        let v = value ?? UserDefaults.standard.string(forKey: Prefs.appearance) ?? system
        switch v {
        case light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil   // suit macOS
        }
    }
}

/// Langue de l'interface. Par défaut, celle de macOS ; on peut la forcer
/// (équivaut au réglage par app de Réglages Système › Langue et région).
enum AppLanguage {
    static let system = "system"
    private static let key = "AppleLanguages"

    /// "system", "fr" ou "en"
    static var current: String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        guard let first = (domain[key] as? [String])?.first else { return system }
        return first.hasPrefix("fr") ? "fr" : first.hasPrefix("en") ? "en" : system
    }

    static func set(_ code: String) {
        if code == system {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set([code], forKey: key)
        }
    }

    /// Relance l'app pour appliquer la nouvelle langue
    @MainActor
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
