import AppKit
import Foundation

/// Tout ce qu'on peut savoir d'une app sans l'ouvrir : identité, signature, notarisation,
/// quarantaine, droits (entitlements) et composants embarqués.
struct AppReport: Equatable {
    // Identité
    let url: URL
    var name: String
    var bundleID: String?
    var version: String?
    var minimumSystem: String?
    var architectures: [String] = []
    var sizeBytes: Int64?

    // Signature
    var signature: Signature = .unknown
    var signatureValid: Bool?
    var signatureError: String?
    var authorities: [String] = []
    var teamID: String?
    var hardenedRuntime = false
    var signedAt: String?

    // Gatekeeper
    var gatekeeper: Gatekeeper = .unknown
    var quarantine: Quarantine?

    // Droits et vie privée
    var entitlements: [Entitlement] = []
    var privacyUsages: [PrivacyUsage] = []

    // Composants
    var loginItems: [String] = []
    var launchServices: [String] = []
    var systemExtensions: [String] = []
    var frameworkCount = 0
    var usesSparkle = false
    var isFromAppStore = false

    enum Signature: Equatable {
        case apple
        case appStore
        case developerID(String)
        case development(String)
        case adHoc
        case selfSigned(String)
        case unsigned
        case unknown

        var title: String {
            switch self {
            case .apple: "Apple"
            case .appStore: String(localized: "Mac App Store")
            case .developerID(let name): name
            case .development(let name): String(localized: "\(name) (développement)")
            case .adHoc: String(localized: "Signature locale (ad hoc)")
            case .selfSigned(let name): String(localized: "\(name) (certificat personnel)")
            case .unsigned: String(localized: "Non signée")
            case .unknown: String(localized: "Inconnue")
            }
        }
    }

    enum Gatekeeper: Equatable {
        case notarized
        case developerID
        case appStore
        case apple
        case rejected(String)
        case unknown

        var title: String {
            switch self {
            case .notarized: String(localized: "Notarisée par Apple")
            case .developerID: String(localized: "Developer ID, non notarisée")
            case .appStore: String(localized: "Mac App Store")
            case .apple: String(localized: "Système Apple")
            case .rejected(let reason): String(localized: "Refusée (\(reason))")
            case .unknown: String(localized: "Inconnu")
            }
        }

        var isAccepted: Bool {
            switch self {
            case .notarized, .developerID, .appStore, .apple: true
            default: false
            }
        }
    }

    struct Quarantine: Equatable {
        /// App qui a téléchargé le fichier (Safari, Chrome…).
        let agent: String?
        let date: Date?
        let raw: String
    }

    struct Entitlement: Identifiable, Equatable {
        let key: String
        let value: String
        var id: String { key }
        var description: String? { AppInspector.entitlementNames[key] }
        /// Assouplit les protections de macOS : à surveiller.
        var isSensitive: Bool { AppInspector.sensitiveEntitlements.contains(key) }
    }

    struct PrivacyUsage: Identifiable, Equatable {
        let key: String
        let text: String
        var id: String { key }
        var title: String { AppInspector.privacyNames[key] ?? key }
    }

    /// Verdict global, du meilleur au pire.
    enum Verdict { case trusted, caution, danger }

    var verdict: Verdict {
        if signatureValid == false || signature == .unsigned { return .danger }
        if case .rejected = gatekeeper {
            return signature == .adHoc || { if case .selfSigned = signature { true } else { false } }()
                ? .caution : .danger
        }
        if gatekeeper == .developerID || entitlements.contains(where: \.isSensitive) { return .caution }
        return gatekeeper.isAccepted ? .trusted : .caution
    }

    var verdictTitle: String {
        if signatureValid == false { return String(localized: "Signature invalide : l'app a été modifiée depuis sa signature") }
        switch signature {
        case .unsigned: return String(localized: "App non signée : son origine ne peut pas être vérifiée")
        case .adHoc: return String(localized: "Signature locale, sans identité de développeur")
        case .selfSigned: return String(localized: "Signée avec un certificat personnel, non reconnu par Apple")
        default: break
        }
        switch gatekeeper {
        case .notarized: return String(localized: "Signée et notarisée par Apple")
        case .appStore: return String(localized: "Distribuée par le Mac App Store")
        case .apple: return String(localized: "App du système, signée par Apple")
        case .developerID: return String(localized: "Signée par un développeur identifié, mais pas notarisée")
        case .rejected: return String(localized: "Gatekeeper refuserait de l'ouvrir")
        case .unknown: return String(localized: "Vérification incomplète")
        }
    }
}

enum AppInspector {
    @MainActor
    static func inspect(_ url: URL) async -> AppReport {
        var report = AppReport(url: url, name: url.deletingPathExtension().lastPathComponent)
        let bundle = Bundle(url: url)
        let info = bundle?.infoDictionary ?? [:]

        // Identité
        report.name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? report.name
        report.bundleID = bundle?.bundleIdentifier
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        report.version = [short, build.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ").nilIfEmpty
        report.minimumSystem = info["LSMinimumSystemVersion"] as? String
        report.privacyUsages = info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted().map {
            AppReport.PrivacyUsage(key: $0, text: info[$0] as? String ?? "")
        }

        // Signature (codesign écrit ses informations sur la sortie d'erreur, réunie ici)
        async let details = SystemCommand.run("/usr/bin/codesign", ["-dv", "--verbose=4", url.path])
        async let verify = SystemCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", url.path])
        async let assessment = SystemCommand.run("/usr/sbin/spctl", ["--assess", "-vv", "--type", "execute", url.path])
        async let entitlementsXML = SystemCommand.run("/usr/bin/codesign", ["-d", "--entitlements", "-", "--xml", url.path])
        async let quarantine = SystemCommand.run("/usr/bin/xattr", ["-p", "com.apple.quarantine", url.path])
        async let size = SystemCommand.run("/usr/bin/du", ["-sk", url.path])

        parseSignature(await details.output, into: &report)
        let verifyResult = await verify
        if report.signature != .unsigned {
            report.signatureValid = verifyResult.succeeded
            if !verifyResult.succeeded {
                report.signatureError = verifyResult.output.split(separator: "\n").first.map(String.init)
            }
        }
        report.gatekeeper = parseGatekeeper(await assessment)
        report.entitlements = parseEntitlements(await entitlementsXML.output)

        let quarantineResult = await quarantine
        if quarantineResult.succeeded {
            report.quarantine = parseQuarantine(quarantineResult.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let kb = await size.output.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) {
            report.sizeBytes = kb * 1024
        }

        // Composants embarqués
        let contents = url.appendingPathComponent("Contents")
        report.loginItems = names(in: contents.appendingPathComponent("Library/LoginItems"))
        report.launchServices = names(in: contents.appendingPathComponent("Library/LaunchServices"))
            + names(in: contents.appendingPathComponent("Library/LaunchDaemons"))
            + names(in: contents.appendingPathComponent("Library/LaunchAgents"))
        report.systemExtensions = names(in: contents.appendingPathComponent("Library/SystemExtensions"))
        let frameworks = names(in: contents.appendingPathComponent("Frameworks"))
        report.frameworkCount = frameworks.count
        report.usesSparkle = frameworks.contains { $0.hasPrefix("Sparkle") } || info["SUFeedURL"] != nil
        report.isFromAppStore = FileManager.default.fileExists(atPath: contents.appendingPathComponent("_MASReceipt").path)
        if report.isFromAppStore && report.signature == .unknown { report.signature = .appStore }
        return report
    }

    /// Retire l'attribut de quarantaine de l'app et de son contenu.
    @MainActor
    static func removeQuarantine(_ url: URL) async throws {
        let result = await SystemCommand.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", url.path])
        if result.succeeded { return }
        // App installée par un autre utilisateur ou par un installeur : droits administrateur
        _ = try await PrivilegedShell.run("/usr/bin/xattr -dr com.apple.quarantine \(Shell.quote(url.path))")
    }

    // MARK: - Analyse des sorties

    private static func parseSignature(_ output: String, into report: inout AppReport) {
        if output.contains("not signed at all") {
            report.signature = .unsigned
            return
        }
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("Authority=") { report.authorities.append(String(line.dropFirst(10))) }
            if line.hasPrefix("TeamIdentifier="), !line.hasSuffix("not set") { report.teamID = String(line.dropFirst(15)) }
            if line.hasPrefix("Timestamp=") { report.signedAt = String(line.dropFirst(10)) }
            if line.hasPrefix("CodeDirectory"), line.contains("runtime") { report.hardenedRuntime = true }
            if line.hasPrefix("Format="), let open = line.lastIndex(of: "("), let close = line.lastIndex(of: ")"), open < close {
                report.architectures = line[line.index(after: open)..<close].split(separator: " ").map(String.init)
            }
        }
        guard let leaf = report.authorities.first else {
            report.signature = output.contains("Signature=adhoc") ? .adHoc : .unknown
            return
        }
        let root = report.authorities.last ?? ""
        if leaf == "Software Signing" {
            report.signature = .apple
        } else if leaf.hasPrefix("Apple Mac OS Application Signing") {
            report.signature = .appStore
        } else if leaf.hasPrefix("Developer ID Application: ") {
            report.signature = .developerID(String(leaf.dropFirst("Developer ID Application: ".count)))
        } else if leaf.hasPrefix("Apple Development: ") || leaf.hasPrefix("Mac Developer: ") {
            let name = leaf.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            report.signature = .development(name)
        } else if root != "Apple Root CA" {
            // Chaîne qui ne remonte pas à Apple : certificat créé soi-même
            report.signature = .selfSigned(leaf)
        } else {
            report.signature = .developerID(leaf)
        }
    }

    /// `spctl --assess -vv` : « accepted » / « rejected », puis « source=Notarized Developer ID ».
    private static func parseGatekeeper(_ result: SystemCommand.Result) -> AppReport.Gatekeeper {
        let out = result.output
        let source = out.split(separator: "\n")
            .first { $0.hasPrefix("source=") }
            .map { String($0.dropFirst(7)) } ?? ""
        if out.contains(": accepted") || (result.succeeded && !source.isEmpty) {
            switch source {
            case "Notarized Developer ID": return .notarized
            case "Developer ID": return .developerID
            case "Mac App Store", "Apple": return source == "Apple" ? .apple : .appStore
            case "Apple System": return .apple
            default: return source.contains("Notarized") ? .notarized : .developerID
            }
        }
        if out.contains("rejected") {
            return .rejected(source.isEmpty ? String(localized: "signature non reconnue") : source)
        }
        return .unknown
    }

    private static func parseEntitlements(_ output: String) -> [AppReport.Entitlement] {
        guard let start = output.range(of: "<?xml") ?? output.range(of: "<plist"),
              let data = String(output[start.lowerBound...]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [] }
        return plist.keys.sorted().map { key in
            let value: String
            switch plist[key] {
            case let bool as Bool: value = bool ? "oui" : "non"
            case let array as [Any]: value = array.map { "\($0)" }.joined(separator: ", ")
            case let other?: value = "\(other)"
            case nil: value = ""
            }
            return AppReport.Entitlement(key: key, value: value)
        }
    }

    /// « 0083;6720a1b2;Safari;UUID » : drapeaux, date (hexadécimal), app, identifiant.
    private static func parseQuarantine(_ raw: String) -> AppReport.Quarantine {
        let parts = raw.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let date = parts.count > 1 ? UInt64(parts[1], radix: 16).map { Date(timeIntervalSince1970: TimeInterval($0)) } : nil
        let agent = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return AppReport.Quarantine(agent: agent, date: date, raw: raw)
    }

    private static func names(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    // MARK: - Libellés

    static let sensitiveEntitlements: Set<String> = [
        "com.apple.security.cs.disable-library-validation",
        "com.apple.security.cs.allow-unsigned-executable-memory",
        "com.apple.security.cs.disable-executable-page-protection",
        "com.apple.security.cs.allow-dyld-environment-variables",
        "com.apple.security.get-task-allow",
        "com.apple.security.cs.debugger",
    ]

    static let entitlementNames: [String: String] = [
        "com.apple.security.app-sandbox": String(localized: "Bac à sable (sandbox) activé"),
        "com.apple.security.network.client": String(localized: "Connexions réseau sortantes"),
        "com.apple.security.network.server": String(localized: "Accepte des connexions réseau entrantes"),
        "com.apple.security.files.user-selected.read-only": String(localized: "Lit les fichiers que tu choisis"),
        "com.apple.security.files.user-selected.read-write": String(localized: "Lit et modifie les fichiers que tu choisis"),
        "com.apple.security.files.downloads.read-write": String(localized: "Accès au dossier Téléchargements"),
        "com.apple.security.files.all": String(localized: "Accès à tous les fichiers"),
        "com.apple.security.device.camera": String(localized: "Caméra"),
        "com.apple.security.device.audio-input": String(localized: "Micro"),
        "com.apple.security.device.microphone": String(localized: "Micro"),
        "com.apple.security.device.usb": String(localized: "Périphériques USB"),
        "com.apple.security.device.bluetooth": "Bluetooth",
        "com.apple.security.personal-information.location": String(localized: "Localisation"),
        "com.apple.security.personal-information.addressbook": String(localized: "Contacts"),
        "com.apple.security.personal-information.calendars": String(localized: "Calendriers"),
        "com.apple.security.personal-information.photos-library": String(localized: "Photothèque"),
        "com.apple.security.automation.apple-events": String(localized: "Pilote d'autres apps (AppleScript)"),
        "com.apple.security.cs.allow-jit": String(localized: "Compilation à la volée (JIT)"),
        "com.apple.security.cs.allow-unsigned-executable-memory": String(localized: "Exécute du code non signé en mémoire"),
        "com.apple.security.cs.disable-library-validation": String(localized: "Charge des bibliothèques non signées par son éditeur"),
        "com.apple.security.cs.allow-dyld-environment-variables": String(localized: "Accepte l'injection de bibliothèques (DYLD)"),
        "com.apple.security.cs.disable-executable-page-protection": String(localized: "Désactive la protection de la mémoire exécutable"),
        "com.apple.security.get-task-allow": String(localized: "Débogable par d'autres processus (build de développement)"),
        "com.apple.security.cs.debugger": String(localized: "Peut déboguer d'autres processus"),
        "com.apple.security.virtualization": String(localized: "Virtualisation"),
        "com.apple.security.hypervisor": String(localized: "Hyperviseur"),
        "com.apple.developer.system-extension.install": String(localized: "Installe des extensions système"),
        "com.apple.developer.endpoint-security.client": String(localized: "Surveillance de la sécurité du système (Endpoint Security)"),
        "com.apple.developer.networking.networkextension": String(localized: "Extension réseau (VPN, filtre)"),
        "com.apple.application-identifier": String(localized: "Identifiant d'application"),
        "com.apple.developer.team-identifier": String(localized: "Identifiant d'équipe"),
        "keychain-access-groups": String(localized: "Groupes du trousseau"),
        "com.apple.security.application-groups": String(localized: "Groupes d'apps (données partagées)"),
    ]

    static let privacyNames: [String: String] = [
        "NSCameraUsageDescription": String(localized: "Caméra"),
        "NSMicrophoneUsageDescription": String(localized: "Micro"),
        "NSContactsUsageDescription": String(localized: "Contacts"),
        "NSCalendarsUsageDescription": String(localized: "Calendriers"),
        "NSCalendarsFullAccessUsageDescription": String(localized: "Calendriers (accès complet)"),
        "NSRemindersUsageDescription": String(localized: "Rappels"),
        "NSRemindersFullAccessUsageDescription": String(localized: "Rappels (accès complet)"),
        "NSPhotoLibraryUsageDescription": String(localized: "Photothèque"),
        "NSLocationUsageDescription": String(localized: "Localisation"),
        "NSLocationWhenInUseUsageDescription": String(localized: "Localisation"),
        "NSAppleEventsUsageDescription": String(localized: "Pilotage d'autres apps"),
        "NSBluetoothAlwaysUsageDescription": "Bluetooth",
        "NSSpeechRecognitionUsageDescription": String(localized: "Reconnaissance vocale"),
        "NSDesktopFolderUsageDescription": String(localized: "Dossier Bureau"),
        "NSDocumentsFolderUsageDescription": String(localized: "Dossier Documents"),
        "NSDownloadsFolderUsageDescription": String(localized: "Dossier Téléchargements"),
        "NSRemovableVolumesUsageDescription": String(localized: "Volumes amovibles"),
        "NSNetworkVolumesUsageDescription": String(localized: "Volumes réseau"),
        "NSSystemAdministrationUsageDescription": String(localized: "Administration du système"),
        "NSLocalNetworkUsageDescription": String(localized: "Réseau local"),
        "NSFaceIDUsageDescription": String(localized: "Touch ID / Face ID"),
        "NSHomeKitUsageDescription": String(localized: "Maison (HomeKit)"),
        "NSMotionUsageDescription": String(localized: "Mouvements"),
    ]
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
