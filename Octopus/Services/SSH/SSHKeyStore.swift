import AppKit
import Foundation
import Observation

/// Une paire de clés de ~/.ssh (privée et/ou publique).
struct SSHKey: Identifiable, Equatable {
    /// Nom de base, ex. « id_ed25519 ».
    let name: String
    let privatePath: String?
    let publicPath: String?
    /// « ED25519 », « RSA », « ECDSA »…
    var type: String?
    var bits: Int?
    /// « SHA256:… »
    var fingerprint: String?
    var comment: String?
    /// `nil` : inconnu (pas de clé privée, ou illisible).
    var hasPassphrase: Bool?
    var isInAgent = false
    let modified: Date?

    var id: String { privatePath ?? publicPath ?? name }

    /// Fichier à passer aux outils : la clé privée si elle existe.
    var mainPath: String { privatePath ?? publicPath ?? name }
}

/// Une clé détenue par l'agent SSH (1Password, trousseau…) sans fichier dans ~/.ssh.
struct AgentKey: Identifiable, Equatable {
    let fingerprint: String
    let bits: Int?
    let type: String?
    let comment: String?
    /// Ligne complète de la clé publique (« ssh-ed25519 AAAA… commentaire »).
    let publicKey: String

    var id: String { fingerprint }
    var name: String { comment ?? fingerprint }

    /// Nom de fichier proposé pour enregistrer la clé publique dans ~/.ssh.
    var suggestedFileName: String {
        let base = (comment ?? "cle-agent")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let cleaned = String(base)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return (cleaned.isEmpty ? "cle-agent" : cleaned) + ".pub"
    }
}

/// Lit et gère les clés de ~/.ssh.
///
/// Les opérations qui demandent une phrase de passe (génération, changement de phrase,
/// ajout à l'agent…) passent par le terminal intégré : la phrase de passe n'est jamais
/// manipulée par l'app.
@MainActor
@Observable
final class SSHKeyStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")

    private(set) var keys: [SSHKey] = []
    /// Clés de l'agent qui n'ont pas de fichier correspondant dans ~/.ssh.
    private(set) var agentOnlyKeys: [AgentKey] = []
    private(set) var isLoading = false
    private(set) var agentAvailable = true
    /// Socket de l'agent utilisé (celui du shell de l'utilisateur s'il en définit un).
    private(set) var agentSocket: String?

    /// L'agent est celui de 1Password (socket dans son Group Container).
    var isOnePasswordAgent: Bool { agentSocket?.localizedCaseInsensitiveContains("1password") ?? false }

    /// Fichiers de ~/.ssh qui ne sont jamais des clés.
    private static let ignored: Set<String> = [
        "config", "known_hosts", "known_hosts.old", "authorized_keys", "authorized_keys2",
        "environment", "rc", ".DS_Store",
    ]

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        var found = Self.findKeys()
        let identities = await Self.agentIdentities()
        let agent = identities.map { Set($0.map(\.fingerprint)) }
        agentAvailable = agent != nil
        agentSocket = SSHEnvironment.current["SSH_AUTH_SOCK"] ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]

        for index in found.indices {
            let key = found[index]
            let info = await SystemCommand.run("/usr/bin/ssh-keygen", ["-l", "-f", key.publicPath ?? key.mainPath])
            if info.succeeded, let parsed = Self.parseFingerprintLine(info.output) {
                found[index].bits = parsed.bits
                found[index].fingerprint = parsed.fingerprint
                found[index].comment = parsed.comment
                found[index].type = parsed.type
            }
            if let fingerprint = found[index].fingerprint {
                found[index].isInAgent = agent?.contains(fingerprint) ?? false
            }
            if let privatePath = key.privatePath {
                // Avec une phrase de passe vide, ssh-keygen échoue si la clé est protégée.
                let test = await SystemCommand.run("/usr/bin/ssh-keygen", ["-y", "-P", "", "-f", privatePath])
                if test.succeeded {
                    found[index].hasPassphrase = false
                } else if test.output.localizedCaseInsensitiveContains("passphrase") {
                    found[index].hasPassphrase = true
                }
            }
        }
        keys = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let fileFingerprints = Set(found.compactMap(\.fingerprint))
        agentOnlyKeys = (identities ?? []).filter { !fileFingerprints.contains($0.fingerprint) }
    }

    // MARK: - Actions natives (sans phrase de passe)

    func copyPublicKey(_ key: SSHKey) -> Bool {
        guard let path = key.publicPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.trimmingCharacters(in: .whitespacesAndNewlines), forType: .string)
        return true
    }

    /// Envoie la clé privée et la clé publique à la Corbeille (récupérables).
    func moveToTrash(_ key: SSHKey) throws {
        for path in [key.privatePath, key.publicPath].compactMap({ $0 }) {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        }
    }

    // MARK: - Commandes pour le terminal

    static func generateCommand(type: KeyType, fileName: String, comment: String, addToKeychain: Bool) -> String {
        let path = directory.appendingPathComponent(fileName).path
        var arguments = ["/usr/bin/ssh-keygen", "-t", type.keygenType]
        if let bits = type.bits { arguments += ["-b", String(bits)] }
        arguments += ["-C", comment, "-f", path]
        var line = Shell.join(arguments)
        if addToKeychain {
            line += " && " + Shell.join(["/usr/bin/ssh-add", "--apple-use-keychain", path])
        }
        return line
    }

    static func changePassphraseCommand(_ key: SSHKey) -> String {
        Shell.join(["/usr/bin/ssh-keygen", "-p", "-f", key.mainPath])
    }

    static func changeCommentCommand(_ key: SSHKey, comment: String) -> String {
        Shell.join(["/usr/bin/ssh-keygen", "-c", "-C", comment, "-f", key.mainPath])
    }

    static func addToAgentCommand(_ key: SSHKey) -> String {
        Shell.join(["/usr/bin/ssh-add", "--apple-use-keychain", key.mainPath])
    }

    static func removeFromAgentCommand(_ key: SSHKey) -> String {
        Shell.join(["/usr/bin/ssh-add", "-d", key.publicPath ?? key.mainPath])
    }

    enum KeyType: String, CaseIterable, Identifiable {
        case ed25519 = "Ed25519"
        case rsa = "RSA 4096"
        case ecdsa = "ECDSA 521"

        var id: Self { self }
        var keygenType: String {
            switch self {
            case .ed25519: "ed25519"
            case .rsa: "rsa"
            case .ecdsa: "ecdsa"
            }
        }
        var bits: Int? {
            switch self {
            case .ed25519: nil
            case .rsa: 4096
            case .ecdsa: 521
            }
        }
        var defaultFileName: String { "id_\(keygenType)" }
    }

    static func fileExists(_ fileName: String) -> Bool {
        let path = directory.appendingPathComponent(fileName).path
        return FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: path + ".pub")
    }

    static var defaultComment: String {
        "\(NSUserName())@\(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)"
    }

    // MARK: - Lecture

    private static func findKeys() -> [SSHKey] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var keys: [String: (priv: String?, pub: String?, date: Date?)] = [:]

        for name in names where !ignored.contains(name) && !name.hasPrefix(".") && !name.hasSuffix(".bak") {
            let path = directory.appendingPathComponent(name).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date

            if name.hasSuffix(".pub") {
                let base = String(name.dropLast(4))
                keys[base, default: (nil, nil, date)].pub = path
            } else if isPrivateKey(path) {
                keys[name, default: (nil, nil, date)].priv = path
                keys[name]?.date = date
            }
        }
        return keys.map { name, files in
            SSHKey(name: name, privatePath: files.priv, publicPath: files.pub, modified: files.date)
        }
    }

    /// Les clés privées commencent par « -----BEGIN … PRIVATE KEY----- ».
    private static func isPrivateKey(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 64)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return head.hasPrefix("-----BEGIN") && head.contains("PRIVATE KEY")
    }

    /// « 256 SHA256:abc… commentaire (ED25519) »
    static func parseFingerprintLine(_ line: String) -> (bits: Int?, fingerprint: String, comment: String?, type: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var rest = parts.count > 2 ? String(parts[2]) : ""
        var type: String?
        if rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") {
            type = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
            rest = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        }
        let comment = rest.isEmpty || rest == "no comment" ? nil : rest
        return (Int(parts[0]), String(parts[1]), comment, type)
    }

    /// Clés chargées dans l'agent ; `nil` si l'agent est injoignable.
    /// `ssh-add -l` (empreintes) et `ssh-add -L` (clés publiques) listent les clés dans le même ordre.
    private static func agentIdentities() async -> [AgentKey]? {
        let environment = await SSHEnvironment.variables()
        let list = await SystemCommand.run("/usr/bin/ssh-add", ["-l"], environment: environment)
        // Code 1 : agent joignable mais vide ; code 2 : pas d'agent.
        if list.status == 2 { return nil }
        guard list.succeeded else { return [] }
        let publicKeys = await SystemCommand.run("/usr/bin/ssh-add", ["-L"], environment: environment)
            .output.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") }

        let lines = list.output.split(separator: "\n").map(String.init)
        return lines.enumerated().compactMap { index, line in
            guard let parsed = parseFingerprintLine(line) else { return nil }
            return AgentKey(fingerprint: parsed.fingerprint, bits: parsed.bits, type: parsed.type,
                            comment: parsed.comment,
                            publicKey: index < publicKeys.count ? publicKeys[index] : "")
        }
    }

    // MARK: - Clés de l'agent

    func copyPublicKey(_ key: AgentKey) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key.publicKey, forType: .string)
    }

    /// Enregistre la clé publique dans ~/.ssh, pour la désigner dans `IdentityFile`
    /// (c'est ainsi qu'on choisit une clé précise de 1Password pour un hôte).
    func savePublicKey(_ key: AgentKey, fileName: String) throws -> String {
        let url = Self.directory.appendingPathComponent(fileName)
        try (key.publicKey + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return url.path
    }

    /// Fichier temporaire contenant la clé publique, pour `ssh-copy-id -i`.
    static func temporaryPublicKeyFile(_ key: AgentKey) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("octopus-\(abs(key.fingerprint.hashValue)).pub")
        try (key.publicKey + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}

// MARK: - 1Password

/// Surveille l'agent SSH de 1Password : app lancée ou non, agent qui répond ou non.
///
/// L'agent de 1Password ne fonctionne que pendant que l'app tourne ; sinon le socket
/// existe toujours mais refuse les connexions (« Connection refused »).
@MainActor
@Observable
final class OnePasswordMonitor {
    enum State: Equatable {
        /// L'agent SSH configuré n'est pas celui de 1Password : rien à afficher.
        case notUsed
        case appNotRunning
        /// App lancée, mais l'agent ne répond pas (désactivé dans les réglages, ou en cours de démarrage).
        case agentUnavailable
        case active(keyCount: Int)
    }

    static let bundleIdentifier = "com.1password.1password"

    private(set) var state: State = .notUsed

    var isActive: Bool { if case .active = state { true } else { false } }

    /// Vérifie toutes les quelques secondes tant que la vue est affichée (tâche annulée avec elle).
    func watch(every seconds: Double = 4) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    func refresh() async {
        let environment = await SSHEnvironment.variables()
        let socket = environment["SSH_AUTH_SOCK"] ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
        let configText = (try? String(contentsOf: SSHConfigStore.url, encoding: .utf8)) ?? ""
        guard socket.localizedCaseInsensitiveContains("1password")
                || configText.localizedCaseInsensitiveContains("com.1password") else {
            state = .notUsed
            return
        }
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
        guard running else {
            state = .appNotRunning
            return
        }
        // Le socket de 1Password, même si le shell en utilise un autre (IdentityAgent dans la config)
        let onePasswordSocket = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock").path
        let result = await SystemCommand.run("/usr/bin/ssh-add", ["-l"], environment: ["SSH_AUTH_SOCK": onePasswordSocket])
        switch result.status {
        case 0: state = .active(keyCount: result.output.split(separator: "\n").count)
        case 1: state = .active(keyCount: 0)
        default: state = .agentUnavailable
        }
    }

    func openApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }
}
