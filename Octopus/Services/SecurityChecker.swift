import Foundation
import Observation

/// Résultat d'une vérification de sécurité.
struct SecurityCheck: Identifiable, Equatable {
    enum Level: Int, Comparable {
        case good, info, warning, bad, unknown

        static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String
    let title: String
    let symbol: String
    var level: Level
    /// Valeur courte affichée en grand : « Activée », « 5326 »…
    var value: String
    /// Explication ou conseil, si utile.
    var detail: String? = nil
}

/// Mise à jour proposée par `softwareupdate --list`.
struct PendingUpdate: Identifiable, Equatable {
    let label: String
    let title: String
    let version: String?
    /// macOS lui-même (redémarrage) : laissé à Réglages Système.
    let isMacOS: Bool
    let needsRestart: Bool

    var id: String { label }
}

/// Vérifications de sécurité inspirées de SilentKnight, sans droits administrateur.
///
/// Les commandes qui demandent `sudo` (vérifier XProtect sur iCloud, installer une mise à jour)
/// sont lancées dans le terminal intégré, où Touch ID fonctionne.
@MainActor
@Observable
final class SecurityChecker {
    private(set) var checks: [SecurityCheck] = []
    private(set) var isChecking = false
    private(set) var lastCheck: Date?

    private(set) var updates: [PendingUpdate]?
    private(set) var isListingUpdates = false
    private(set) var updatesError: String?

    /// Niveau le plus préoccupant parmi les vérifications (hors « info »).
    var overallLevel: SecurityCheck.Level {
        checks.map(\.level).filter { $0 != .info }.max() ?? .unknown
    }

    var problemCount: Int {
        checks.filter { $0.level == .warning || $0.level == .bad }.count
    }

    func checkAll() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        let history = Self.installHistory()
        async let sip = Self.sip()
        async let ssv = Self.signedSystemVolume()
        async let gatekeeper = Self.gatekeeper()
        async let fileVault = Self.fileVault()
        async let firewall = Self.firewall()
        async let boot = Self.bootPolicy()
        async let xprotect = Self.xprotect(history: history)
        let remediator = Self.xprotectRemediator(history: history)
        let automatic = Self.automaticUpdates()

        let (bootCheck, firmware) = await boot
        checks = await [sip, ssv, bootCheck, gatekeeper, fileVault, firewall, automatic, xprotect, remediator, firmware]
        lastCheck = .now

        // Lecture du journal plus lente (quelques secondes) : la carte se complète ensuite.
        let scans = await Self.remediatorScans()
        if let index = checks.firstIndex(where: { $0.id == "xpr" }) {
            checks[index].level = max(checks[index].level, scans.level)
            checks[index].detail = [checks[index].detail, scans.summary].compactMap { $0 }.joined(separator: "\n")
        }
    }

    /// Dernière réponse d'Apple, partagée entre les ouvertures de la vue : inutile de
    /// réinterroger le serveur à chaque passage dans l'onglet.
    private static var cachedUpdates: (date: Date, updates: [PendingUpdate])?
    private static let updatesCacheDuration: TimeInterval = 15 * 60

    /// Interroge le serveur de mises à jour d'Apple : souvent 10 à 60 secondes.
    /// Sans `force`, réutilise une réponse de moins de 15 minutes.
    func listUpdates(force: Bool = false) async {
        if !force, let cached = Self.cachedUpdates,
           Date.now.timeIntervalSince(cached.date) < Self.updatesCacheDuration {
            updates = cached.updates
            return
        }
        guard !isListingUpdates else { return }
        isListingUpdates = true
        updatesError = nil
        defer { isListingUpdates = false }

        let result = await SystemCommand.run("/usr/sbin/softwareupdate", ["--list", "--include-config-data"])
        if result.output.contains("No new software available") {
            updates = []
            Self.cachedUpdates = (.now, [])
        } else if result.output.contains("* Label:") {
            let parsed = Self.parseUpdates(result.output)
            updates = parsed
            Self.cachedUpdates = (.now, parsed)
        } else {
            updates = nil
            updatesError = result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "softwareupdate n'a rien renvoyé (code \(result.status)).")
                : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - Vérifications

    private static func sip() async -> SecurityCheck {
        let out = await SystemCommand.run("/usr/bin/csrutil", ["status"]).output.lowercased()
        var check = SecurityCheck(id: "sip", title: String(localized: "Protection de l'intégrité du système (SIP)"),
                                  symbol: "lock.shield", level: .unknown, value: String(localized: "Inconnue"))
        if out.contains("status: enabled") {
            check.level = .good
            check.value = String(localized: "Activée")
            if out.contains("custom configuration") || out.contains("disabled") {
                check.level = .warning
                check.value = String(localized: "Partielle")
                check.detail = String(localized: "SIP est activée avec une configuration personnalisée : certaines protections sont coupées.")
            }
        } else if out.contains("status: disabled") {
            check.level = .bad
            check.value = String(localized: "Désactivée")
            check.detail = String(localized: "Réactive-la depuis la récupération macOS avec « csrutil enable ».")
        }
        return check
    }

    private static func signedSystemVolume() async -> SecurityCheck {
        let out = await SystemCommand.run("/usr/bin/csrutil", ["authenticated-root", "status"]).output.lowercased()
        var check = SecurityCheck(id: "ssv", title: String(localized: "Volume système signé (SSV)"),
                                  symbol: "checkmark.seal", level: .unknown, value: String(localized: "Inconnu"))
        if out.contains("enabled") {
            check.level = .good
            check.value = String(localized: "Activé")
        } else if out.contains("disabled") {
            check.level = .bad
            check.value = String(localized: "Désactivé")
            check.detail = String(localized: "Le volume système n'est plus vérifié cryptographiquement au démarrage.")
        }
        return check
    }

    private static func gatekeeper() async -> SecurityCheck {
        let out = await SystemCommand.run("/usr/sbin/spctl", ["--status"]).output.lowercased()
        var check = SecurityCheck(id: "gatekeeper", title: "Gatekeeper",
                                  symbol: "hand.raised", level: .unknown, value: String(localized: "Inconnu"))
        if out.contains("assessments enabled") {
            check.level = .good
            check.value = String(localized: "Activé")
        } else if out.contains("assessments disabled") {
            check.level = .bad
            check.value = String(localized: "Désactivé")
            check.detail = String(localized: "Les apps téléchargées ne sont plus vérifiées avant leur ouverture.")
        }
        return check
    }

    private static func fileVault() async -> SecurityCheck {
        let out = await SystemCommand.run("/usr/bin/fdesetup", ["status"]).output
        var check = SecurityCheck(id: "filevault", title: "FileVault",
                                  symbol: "lock.doc", level: .unknown, value: String(localized: "Inconnu"))
        if out.contains("FileVault is On") {
            check.level = .good
            check.value = String(localized: "Activé")
        } else if out.contains("FileVault is Off") {
            check.level = .warning
            check.value = String(localized: "Désactivé")
            check.detail = String(localized: "Le disque n'est pas chiffré : quelqu'un qui a ton Mac en main peut lire tes fichiers.")
        }
        if out.contains("Encryption in progress") || out.contains("Decryption in progress") {
            check.level = .info
            check.value = String(localized: "En cours")
            check.detail = out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return check
    }

    private static func firewall() async -> SecurityCheck {
        let out = await SystemCommand.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"])
            .output.lowercased()
        var check = SecurityCheck(id: "firewall", title: "Coupe-feu",
                                  symbol: "flame", level: .unknown, value: String(localized: "Inconnu"))
        if out.contains("enabled") {
            check.level = .good
            check.value = String(localized: "Activé")
        } else if out.contains("disabled") {
            check.level = .warning
            check.value = String(localized: "Désactivé")
            check.detail = String(localized: "À activer dans Réglages Système › Réseau › Coupe-feu, surtout sur un réseau public.")
        }
        return check
    }

    /// Réglages de Réglages Système › Mises à jour logicielles › Mises à jour automatiques.
    private static func automaticUpdates() -> SecurityCheck {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist")
        let prefs = (try? Data(contentsOf: url))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        // Clé absente = réglage par défaut, c'est-à-dire activé.
        func enabled(_ key: String) -> Bool { (prefs[key] as? Bool) ?? true }

        var off: [String] = []
        if !enabled("AutomaticCheckEnabled") { off.append(String(localized: "la recherche automatique")) }
        if !enabled("ConfigDataInstall") { off.append(String(localized: "les fichiers de sécurité (XProtect…)")) }
        if !enabled("CriticalUpdateInstall") { off.append(String(localized: "les réponses de sécurité")) }

        var check = SecurityCheck(id: "autoupdate", title: String(localized: "Mises à jour de sécurité automatiques"),
                                  symbol: "arrow.triangle.2.circlepath", level: .good, value: String(localized: "Activées"))
        if !off.isEmpty {
            check.level = .warning
            check.value = String(localized: "Partielles")
            check.detail = String(localized: "Désactivé : \(off.joined(separator: ", ")). Réactive-les dans Réglages Système › Général › Mise à jour de logiciels.")
        }
        return check
    }

    /// Au-delà, une absence de mise à jour de XProtect devient suspecte
    /// (Apple publie en général une nouvelle version toutes les une à trois semaines).
    private static let staleAfterDays = 45

    private static func xprotect(history: [InstallRecord]) async -> SecurityCheck {
        var check = SecurityCheck(id: "xprotect", title: "XProtect",
                                  symbol: "shield.lefthalf.filled", level: .good, value: String(localized: "Inconnue"))
        // macOS 15 et plus : `xprotect version` lit la copie réellement utilisée (/var/protected/xprotect)
        // « Version: 5371 Installed: 2026-11-03 20:20:43 +0000 »
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/xprotect") {
            let out = await SystemCommand.run("/usr/bin/xprotect", ["version"]).output
            if let version = match(#"Version:\s*(\d+)"#, in: out) {
                check.value = version
            }
        }
        if check.value == "Inconnue",
           let version = bundleVersion("/Library/Apple/System/Library/CoreServices/XProtect.bundle") {
            check.value = version
        }

        let last = history.last(where: { $0.name.hasPrefix("XProtectPlistConfigData") || $0.name == "XProtectCloudKitUpdate" })
        if let last {
            check.detail = last.name == "XProtectCloudKitUpdate" ? String(localized: "Mis à jour \(relative(last.date)) (par iCloud)") : String(localized: "Mis à jour \(relative(last.date)) (par Mise à jour de logiciels)")
            if daysSince(last.date) > staleAfterDays {
                check.level = .warning
                check.detail! += String(localized: ". Aucune mise à jour depuis plus de \(staleAfterDays) jours : lance « Vérifier sur iCloud ».")
            }
        } else if check.value == "Inconnue" {
            check.level = .unknown
        }
        return check
    }

    private static func xprotectRemediator(history: [InstallRecord]) -> SecurityCheck {
        var check = SecurityCheck(id: "xpr", title: String(localized: "XProtect Remediator"),
                                  symbol: "cross.case", level: .good, value: String(localized: "Inconnue"))
        if let version = bundleVersion("/Library/Apple/System/Library/CoreServices/XProtect.app") {
            check.value = version
        }
        if let last = history.last(where: { $0.name.hasPrefix("XProtectPayloads") }) {
            if check.value == "Inconnue", let version = last.version { check.value = version }
            check.detail = String(localized: "Mis à jour \(relative(last.date))")
        }
        if check.value == "Inconnue" { check.level = .unknown }
        return check
    }

    /// Règle de démarrage des Mac Apple Silicon (Informations système › Contrôleur), sans sudo.
    /// Renvoie la carte « Démarrage sécurisé » et la carte « Firmware ».
    private static func bootPolicy() async -> (SecurityCheck, SecurityCheck) {
        var boot = SecurityCheck(id: "secureboot", title: String(localized: "Démarrage sécurisé"),
                                 symbol: "power", level: .unknown, value: String(localized: "Inconnu"))
        var firmware = SecurityCheck(id: "firmware", title: "Firmware",
                                     symbol: "memorychip", level: .info, value: String(localized: "Inconnu"))

        let bridge = await systemProfiler("SPiBridgeDataType")
        // Les valeurs sont dans la langue du Mac (« Activé », « Sécurité maximale »…)
        if let secureBoot = bridge["ibridge_secure_boot"] as? String {
            boot.value = secureBoot
            let full = ["maximale", "full", "complète", "complete"].contains { secureBoot.lowercased().contains($0) }
            boot.level = full ? .good : .warning
            if !full {
                boot.detail = String(localized: "Le Mac démarre avec une sécurité réduite (souvent pour une extension noyau). À remettre en sécurité maximale depuis la récupération si ce n'est plus nécessaire.")
            }
            var extras: [String] = []
            if let ctrr = bridge["ibridge_sb_ctrr"] as? String { extras.append(String(localized: "Kernel CTRR : \(ctrr)")) }
            if let args = bridge["ibridge_sb_boot_args"] as? String { extras.append(String(localized: "Filtrage des arguments : \(args)")) }
            if let kext = bridge["ibridge_sb_other_kext"] as? String {
                extras.append(String(localized: "Toutes extensions noyau autorisées : \(kext)"))
                if isAffirmative(kext) {
                    boot.level = max(boot.level, .warning)
                }
            }
            if !extras.isEmpty {
                boot.detail = ([boot.detail] + [extras.joined(separator: " · ")]).compactMap { $0 }.joined(separator: "\n")
            }
        }

        if let build = bridge["ibridge_build"] as? String {
            firmware.value = build.replacingOccurrences(of: "mBoot-", with: "")
        } else {
            // Mac Intel ou format inattendu : version de la Boot ROM
            let hardware = await systemProfiler("SPHardwareDataType")
            if let bootROM = hardware["boot_rom_version"] as? String { firmware.value = bootROM }
            if boot.value == "Inconnu" {
                boot.level = .info
                boot.detail = String(localized: "Non disponible sur ce Mac.")
            }
        }
        return (boot, firmware)
    }

    /// Analyses de XProtect Remediator sur les dernières 36 heures, d'après le journal système.
    private static func remediatorScans() async -> (level: SecurityCheck.Level, summary: String?) {
        let out = await SystemCommand.run("/usr/bin/log", [
            "show", "--last", "36h", "--style", "ndjson",
            "--predicate", #"subsystem == "com.apple.XProtectFramework.PluginAPI" && category == "XPEvent.structured""#,
        ]).output

        var sessions = 0, checks = 0, threats: [String] = [], failures = 0
        for line in out.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let process = (event["processImagePath"] as? String)?.split(separator: "/").last,
                  let messageData = (event["eventMessage"] as? String)?.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any]
            else { continue }
            let status = message["status_message"] as? String ?? ""
            // Le chef d'orchestre lance une série d'analyses ; chaque module en rend compte ensuite.
            if process == "XProtectRemediatorConductor" {
                sessions += 1
                continue
            }
            checks += 1
            let plugin = String(process.replacingOccurrences(of: "XProtectRemediator", with: ""))
            switch status {
            case "Success", "NoThreatDetected": break
            case let s where s.localizedCaseInsensitiveContains("threat") || s.localizedCaseInsensitiveContains("remediat"):
                threats.append("\(plugin) : \(s)")
            default:
                failures += 1
            }
        }

        guard sessions + checks > 0 else {
            return (.info, String(localized: "Aucune analyse dans le journal des 36 dernières heures."))
        }
        var summary = String(localized: "36 dernières heures : \(sessions) séries d'analyses, \(checks) contrôles")
        if failures > 0 { summary += String(localized: ", \(failures) interrompus ou en erreur") }
        if !threats.isEmpty {
            return (.bad, summary + String(localized: ".\nMenaces signalées : ") + threats.joined(separator: ", "))
        }
        return (.good, summary + String(localized: ", aucune menace."))
    }

    // MARK: - Outils

    struct InstallRecord {
        let date: Date
        let name: String
        let version: String?
    }

    /// Historique des installations de macOS (/Library/Receipts), du plus ancien au plus récent.
    private static func installHistory() -> [InstallRecord] {
        let url = URL(fileURLWithPath: "/Library/Receipts/InstallHistory.plist")
        guard let data = try? Data(contentsOf: url),
              let entries = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let date = entry["date"] as? Date, let name = entry["displayName"] as? String else { return nil }
            return InstallRecord(date: date, name: name, version: entry["displayVersion"] as? String)
        }
        .sorted { $0.date < $1.date }
    }

    /// Premier élément de `SP…DataType` dans `system_profiler -json`.
    private static func systemProfiler(_ dataType: String) async -> [String: Any] {
        let out = await SystemCommand.run("/usr/sbin/system_profiler", [dataType, "-json"]).output
        guard let data = out.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json[dataType] as? [[String: Any]])?.first else { return [:] }
        return first
    }

    /// « Oui », « Yes », « Ja », « Sí »… (valeurs localisées de system_profiler).
    private static func isAffirmative(_ value: String) -> Bool {
        ["oui", "yes", "ja", "sí", "si", "sì", "sim", "да", "はい", "是"].contains(value.lowercased())
    }

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              result.numberOfRanges > 1,
              let range = Range(result.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func daysSince(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: date, to: .now).day ?? 0
    }

    /// « il y a 3 jours (4 nov. 2026) »
    private static func relative(_ date: Date) -> String {
        let ago = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
        return "\(ago) (\(date.formatted(date: .abbreviated, time: .omitted)))"
    }

    private static func bundleVersion(_ bundlePath: String) -> String? {
        let url = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return (plist["CFBundleShortVersionString"] ?? plist["CFBundleVersion"]) as? String
    }

    /// Analyse la sortie de `softwareupdate --list` :
    ///   * Label: XProtectPlistConfigData_10_15-5331
    ///       Title: XProtectPlistConfigData, Version: 5331, Size: 1204KiB, Recommended: YES,
    static func parseUpdates(_ output: String) -> [PendingUpdate] {
        let lines = output.components(separatedBy: .newlines)
        var updates: [PendingUpdate] = []
        for (index, line) in lines.enumerated() {
            guard let range = line.range(of: "* Label: ") else { continue }
            let label = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let details = index + 1 < lines.count ? lines[index + 1] : ""
            let fields = Dictionary(
                details.split(separator: ",").compactMap { part -> (String, String)? in
                    let pair = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    return pair.count == 2 ? (pair[0], pair[1]) : nil
                },
                uniquingKeysWith: { first, _ in first }
            )
            let title = fields["Title"] ?? label
            updates.append(PendingUpdate(
                label: label,
                title: title,
                version: fields["Version"],
                isMacOS: title.hasPrefix("macOS"),
                needsRestart: (fields["Action"] ?? "").lowercased().contains("restart")
            ))
        }
        return updates
    }
}
