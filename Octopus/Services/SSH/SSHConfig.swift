import Darwin
import Foundation
import Observation
import SwiftUI

/// Fichier ~/.ssh/config découpé en blocs, sans rien perdre.
///
/// Un bloc qui n'a pas été modifié est réécrit tel quel (commentaires, indentation, options
/// inconnues compris). Seul un bloc modifié est régénéré, dans une forme standard.
struct SSHConfigFile: Equatable {
    /// Lignes avant le premier bloc (options globales, Include…), conservées telles quelles.
    var preamble: [String]
    var blocks: [SSHHostBlock]

    static func parse(_ text: String) -> SSHConfigFile {
        var preamble: [String] = []
        var blocks: [SSHHostBlock] = []
        var lines = text.components(separatedBy: "\n")
        // Un fichier terminé par un saut de ligne produit une dernière chaîne vide
        if lines.last == "" { lines.removeLast() }

        for line in lines {
            if let found = directive(line), found.keyword == "host" || found.keyword == "match" {
                blocks.append(SSHHostBlock(isMatch: found.keyword == "match", header: found.value, rawLines: [line]))
            } else if blocks.isEmpty {
                preamble.append(line)
            } else {
                blocks[blocks.count - 1].rawLines.append(line)
            }
        }
        return SSHConfigFile(preamble: preamble, blocks: blocks)
    }

    func serialized() -> String {
        var lines = preamble
        for block in blocks {
            lines += block.lines()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// « Mot-clé valeur » ou « Mot-clé=valeur » ; `nil` pour un commentaire ou une ligne vide.
    static func directive(_ line: String) -> (keyword: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed.lowercased(), "")
        }
        let keyword = String(trimmed[..<separator]).lowercased()
        var value = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return (keyword, value)
    }
}

/// Un bloc « Host … » (ou « Match … », affiché mais pas modifiable par le formulaire).
struct SSHHostBlock: Identifiable, Equatable {
    let id = UUID()
    let isMatch: Bool
    /// Motifs du bloc : « github.com », « *.lan homelab »…
    var header: String
    /// Lignes d'origine, de « Host » jusqu'au bloc suivant (lignes vides et commentaires compris).
    var rawLines: [String]
    /// Formulaire édité : `nil` tant que le bloc n'a pas été modifié.
    var edited: SSHHostForm?

    var patterns: [String] { header.split(whereSeparator: \.isWhitespace).map(String.init) }
    private var hasWildcard: Bool { header.contains(where: { "*?!".contains($0) }) }
    /// Un seul alias sans joker : utilisable directement avec `ssh alias`.
    var isConcreteHost: Bool { !isMatch && patterns.count == 1 && !hasWildcard }
    /// Plusieurs alias précis (« Host a b c ») : options communes à ces hôtes.
    var isSharedOptions: Bool { !isMatch && patterns.count > 1 && !hasWildcard }

    /// Vrai si ce bloc s'applique à `alias` (motifs avec jokers et négations « ! » compris).
    func applies(to alias: String) -> Bool {
        guard !isMatch else { return false }
        var matched = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if fnmatch(String(pattern.dropFirst()), alias, 0) == 0 { return false }
            } else if fnmatch(pattern, alias, 0) == 0 {
                matched = true
            }
        }
        return matched
    }

    /// Options du bloc (mot-clé tel qu'écrit, valeur), sans la ligne « Host ».
    var directives: [(keyword: String, value: String)] {
        lines().dropFirst().compactMap { line -> (keyword: String, value: String)? in
            guard let found = SSHConfigFile.directive(line) else { return nil }
            let written = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .first.map(String.init) ?? found.keyword
            return (keyword: written, value: found.value)
        }
    }

    /// Valeur d'une option du bloc, telle qu'elle apparaît dans le fichier.
    func value(of keyword: String) -> String? {
        if let edited { return edited.value(of: keyword) }
        for line in rawLines.dropFirst() {
            if let found = SSHConfigFile.directive(line), found.keyword == keyword.lowercased() { return found.value }
        }
        return nil
    }

    var form: SSHHostForm { edited ?? SSHHostForm(block: self) }

    func lines() -> [String] {
        guard let edited else { return rawLines }
        return edited.lines()
    }
}

/// Champs modifiables d'un hôte. Les options sans champ dédié sont gardées en texte libre.
struct SSHHostForm: Equatable {
    var host = ""
    var hostName = ""
    var user = ""
    var port = ""
    var identityFile = ""
    var proxyJump = ""
    var identitiesOnly = false
    var addKeysToAgent = false
    var useKeychain = false
    /// Autres lignes du bloc (options, commentaires), réécrites telles quelles.
    var otherLines = ""

    static let indent = "    "

    init() {}

    init(block: SSHHostBlock) {
        host = block.header
        var others: [String] = []
        for line in block.rawLines.dropFirst() {
            guard let found = SSHConfigFile.directive(line) else {
                others.append(line.trimmingCharacters(in: .whitespaces))
                continue
            }
            let value = found.value
            switch found.keyword {
            case "hostname" where hostName.isEmpty: hostName = value
            case "user" where user.isEmpty: user = value
            case "port" where port.isEmpty: port = value
            case "identityfile" where identityFile.isEmpty: identityFile = value
            case "proxyjump" where proxyJump.isEmpty: proxyJump = value
            case "identitiesonly": identitiesOnly = value.lowercased() == "yes"
            case "addkeystoagent": addKeysToAgent = value.lowercased() == "yes"
            case "usekeychain": useKeychain = value.lowercased() == "yes"
            default: others.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        // Les lignes vides de fin de bloc ne sont que de l'espacement
        while others.last?.isEmpty == true { others.removeLast() }
        otherLines = others.joined(separator: "\n")
    }

    func value(of keyword: String) -> String? {
        switch keyword.lowercased() {
        case "hostname": hostName.nilIfEmpty
        case "user": user.nilIfEmpty
        case "port": port.nilIfEmpty
        case "identityfile": identityFile.nilIfEmpty
        case "proxyjump": proxyJump.nilIfEmpty
        default: nil
        }
    }

    func lines() -> [String] {
        var lines = ["Host \(host.trimmingCharacters(in: .whitespaces))"]
        func add(_ keyword: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return }
            // Les chemins avec espaces doivent être entre guillemets
            let quoted = value.contains(" ") && !value.hasPrefix("\"") ? "\"\(value)\"" : value
            lines.append("\(Self.indent)\(keyword) \(quoted)")
        }
        add("HostName", hostName)
        add("User", user)
        add("Port", port)
        add("IdentityFile", identityFile)
        add("ProxyJump", proxyJump)
        if identitiesOnly { lines.append("\(Self.indent)IdentitiesOnly yes") }
        if addKeysToAgent { lines.append("\(Self.indent)AddKeysToAgent yes") }
        if useKeychain { lines.append("\(Self.indent)UseKeychain yes") }
        for line in otherLines.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            lines.append(Self.indent + trimmed)
        }
        lines.append("")
        return lines
    }

    var isValid: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Lecture, écriture, test

@MainActor
@Observable
final class SSHConfigStore {
    static let url = SSHKeyStore.directory.appendingPathComponent("config")
    static let backupURL = SSHKeyStore.directory.appendingPathComponent("config.octopus-backup")

    private(set) var file = SSHConfigFile(preamble: [], blocks: [])
    /// Contenu lu sur le disque : sert à savoir s'il reste des changements à enregistrer.
    private var original = SSHConfigFile(preamble: [], blocks: [])
    private(set) var errorMessage: String?
    /// Résultat du dernier test de connexion, par alias.
    private(set) var testResults: [String: ConnectionTest] = [:]
    private(set) var testing: Set<String> = []
    /// Augmente à chaque rechargement ou annulation : les formulaires ouverts se réinitialisent.
    private(set) var revision = 0

    var hasChanges: Bool { file.serialized() != original.serialized() }

    func reload() {
        let text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        file = SSHConfigFile.parse(text)
        original = file
        errorMessage = nil
        revision += 1
    }

    func update(_ id: SSHHostBlock.ID, with form: SSHHostForm) {
        guard let index = file.blocks.firstIndex(where: { $0.id == id }) else { return }
        // Formulaire simplement chargé, sans modification : le bloc reste tel quel dans le fichier
        if file.blocks[index].edited == nil && form == SSHHostForm(block: file.blocks[index]) { return }
        file.blocks[index].edited = form
        file.blocks[index].header = form.host.trimmingCharacters(in: .whitespaces)
    }

    @discardableResult
    func addHost(_ form: SSHHostForm) -> SSHHostBlock.ID {
        // Une ligne vide avant le nouveau bloc, s'il n'y en a pas déjà
        if let last = file.blocks.indices.last, file.blocks[last].edited == nil,
           file.blocks[last].rawLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == false {
            file.blocks[last].rawLines.append("")
        }
        var block = SSHHostBlock(isMatch: false, header: form.host, rawLines: [])
        block.edited = form
        file.blocks.append(block)
        return block.id
    }

    func delete(_ id: SSHHostBlock.ID) {
        file.blocks.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        file.blocks.move(fromOffsets: source, toOffset: destination)
    }

    func discardChanges() {
        file = original
        revision += 1
    }

    /// Écrit le fichier après en avoir gardé une copie (config.octopus-backup).
    func save() {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: SSHKeyStore.directory.path) {
                try fm.createDirectory(at: SSHKeyStore.directory, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            if fm.fileExists(atPath: Self.url.path) {
                try? fm.removeItem(at: Self.backupURL)
                try fm.copyItem(at: Self.url, to: Self.backupURL)
            }
            try file.serialized().write(to: Self.url, atomically: true, encoding: .utf8)
            // ssh refuse un fichier de configuration lisible par les autres utilisateurs
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
            reload()
        } catch {
            errorMessage = "Enregistrement impossible : \(error.localizedDescription)"
        }
    }

    // MARK: - Test de connexion

    enum ConnectionTest: Equatable {
        case success
        case authenticationFailed
        /// Serveur joignable, mais l'agent (1Password) attend une validation par Touch ID
        /// qu'une connexion non interactive ne peut pas obtenir.
        case needsAgentApproval
        case hostKeyProblem
        case unreachable(String)

        var label: String {
            switch self {
            case .success: "Connexion réussie"
            case .authenticationFailed: "Joignable, authentification refusée"
            case .needsAgentApproval: "Joignable, validation 1Password requise"
            case .hostKeyProblem: "Clé d'hôte inconnue ou modifiée"
            case .unreachable(let reason): "Injoignable : \(reason)"
            }
        }

        var isSuccess: Bool { self == .success }
        /// Serveur atteint : seule l'authentification reste à faire.
        var isReachable: Bool { self == .success || self == .authenticationFailed || self == .needsAgentApproval }
    }

    /// Connexion interactive dans le terminal : affiche les questions et les erreurs de ssh.
    static func interactiveTestCommand(alias: String) -> String {
        Shell.join(["/usr/bin/ssh", "-o", "ConnectTimeout=6", alias, "echo Connexion réussie"])
    }

    /// Ajoute une clé publique au ~/.ssh/authorized_keys d'un hôte (le mot de passe est demandé une fois).
    static func copyKeyCommand(publicKey: String, destination: String) -> String {
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-copy-id") {
            return Shell.join(["/usr/bin/ssh-copy-id", "-i", publicKey, destination])
        }
        // Repli pour les anciens macOS sans ssh-copy-id
        let remote = "umask 077; mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
        return "cat \(Shell.quote(publicKey)) | /usr/bin/ssh \(Shell.quote(destination)) \(Shell.quote(remote))"
    }

    /// L'agent SSH est celui de 1Password (dans le shell ou via IdentityAgent dans la config).
    private var usesOnePassword: Bool {
        let socket = SSHEnvironment.current["SSH_AUTH_SOCK"] ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] ?? ""
        return socket.localizedCaseInsensitiveContains("1password")
            || file.serialized().localizedCaseInsensitiveContains("2BUA8C4S2C.com.1password")
    }

    /// Connexion non interactive (sans mot de passe ni question) qui se referme aussitôt.
    func test(alias: String) async {
        testing.insert(alias)
        defer { testing.remove(alias) }
        let result = await SystemCommand.run("/usr/bin/ssh", [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=6",
            "-o", "StrictHostKeyChecking=yes",
            alias, "exit",
        ], environment: await SSHEnvironment.variables())
        let out = result.output
        let test: ConnectionTest
        if result.succeeded {
            test = .success
        } else if out.contains("Permission denied") || out.contains("Too many authentication failures") {
            test = usesOnePassword ? .needsAgentApproval : .authenticationFailed
        } else if out.contains("Host key verification failed") || out.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
            test = .hostKeyProblem
        } else {
            let reason = out.split(separator: "\n").last.map(String.init)?
                .replacingOccurrences(of: "ssh: ", with: "") ?? "code \(result.status)"
            test = .unreachable(reason)
        }
        testResults[alias] = test
    }
}
