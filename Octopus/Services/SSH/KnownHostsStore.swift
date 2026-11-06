import Foundation
import Observation

/// Une ligne de ~/.ssh/known_hosts.
struct KnownHost: Identifiable, Equatable {
    /// Numéro de ligne dans le fichier (à partir de 1) : identifiant stable jusqu'au rechargement.
    let line: Int
    /// Noms et adresses, ou `nil` si la ligne est hachée (HashKnownHosts).
    let hosts: [String]?
    let keyType: String
    /// « @cert-authority » ou « @revoked », le cas échéant.
    let marker: String?

    var id: Int { line }

    var displayName: String {
        guard let hosts else { return String(localized: "Hôte haché") }
        return hosts.joined(separator: ", ")
    }

    var shortKeyType: String {
        keyType
            .replacingOccurrences(of: "ssh-", with: "")
            .replacingOccurrences(of: "ecdsa-sha2-", with: "ecdsa ")
            .uppercased()
    }
}

/// Lit et nettoie ~/.ssh/known_hosts.
@MainActor
@Observable
final class KnownHostsStore {
    static let url = SSHKeyStore.directory.appendingPathComponent("known_hosts")

    private(set) var entries: [KnownHost] = []
    private(set) var message: String?

    func reload() {
        let text = (try? String(contentsOf: Self.url, encoding: .utf8)) ?? ""
        entries = text.components(separatedBy: "\n").enumerated().compactMap { index, line in
            Self.parse(line, number: index + 1)
        }
    }

    static func parse(_ line: String, number: Int) -> KnownHost? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        var fields = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        var marker: String?
        if fields.first?.hasPrefix("@") == true { marker = fields.removeFirst() }
        guard fields.count >= 3 else { return nil }
        let hosts = fields[0].hasPrefix("|1|") ? nil : fields[0].split(separator: ",").map(String.init)
        return KnownHost(line: number, hosts: hosts, keyType: fields[1], marker: marker)
    }

    /// Supprime les lignes choisies (une copie est gardée dans known_hosts.old, comme ssh-keygen -R).
    func remove(lines: Set<Int>) {
        do {
            let text = try String(contentsOf: Self.url, encoding: .utf8)
            try backup()
            let kept = text.components(separatedBy: "\n").enumerated()
                .filter { !lines.contains($0.offset + 1) }
                .map(\.element)
            try kept.joined(separator: "\n").write(to: Self.url, atomically: true, encoding: .utf8)
            message = lines.count == 1 ? String(localized: "1 entrée supprimée.") : String(localized: "\(lines.count) entrées supprimées.")
        } catch {
            message = String(localized: "Suppression impossible : \(error.localizedDescription)")
        }
        reload()
    }

    /// Supprime toutes les clés d'un hôte, y compris les lignes hachées (ssh-keygen -R).
    func remove(host: String) async {
        let host = host.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        let result = await SystemCommand.run("/usr/bin/ssh-keygen", ["-R", host, "-f", Self.url.path])
        if result.output.contains("updated") {
            message = String(localized: "Clés de « \(host) » supprimées (copie dans known_hosts.old).")
        } else if result.succeeded {
            message = String(localized: "Aucune entrée pour « \(host) ».")
        } else {
            message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        reload()
    }

    private func backup() throws {
        let old = Self.url.deletingLastPathComponent().appendingPathComponent("known_hosts.old")
        try? FileManager.default.removeItem(at: old)
        try FileManager.default.copyItem(at: Self.url, to: old)
    }
}
