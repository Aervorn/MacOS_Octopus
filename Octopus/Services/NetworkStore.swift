import Darwin
import Foundation
import Observation

/// Interface réseau active et ses adresses.
struct NetworkInterface: Identifiable, Equatable {
    /// « en0 », « utun3 »…
    let device: String
    /// « Wi-Fi », « Ethernet »… (nom du port matériel), si connu.
    var portName: String?
    var ipv4: [String] = []
    var ipv6: [String] = []

    var id: String { device }
    var isVPN: Bool { device.hasPrefix("utun") || device.hasPrefix("ipsec") || device.hasPrefix("ppp") }
    var title: String { portName ?? (isVPN ? "VPN / tunnel" : device) }
}

/// État du réseau : interfaces, routeur, DNS, IP publique.
@MainActor
@Observable
final class NetworkStore {
    private(set) var interfaces: [NetworkInterface] = []
    private(set) var gateway: String?
    private(set) var defaultInterface: String?
    private(set) var dnsServers: [String] = []
    private(set) var publicIPv4: String?
    private(set) var publicIPv6: String?
    private(set) var isFetchingPublicIP = false
    private(set) var message: String?

    func reload() async {
        var found = Self.readInterfaces()
        let ports = Self.parseHardwarePorts(await SystemCommand.run("/usr/sbin/networksetup", ["-listallhardwareports"]).output)
        for index in found.indices { found[index].portName = ports[found[index].device] }

        async let route = SystemCommand.run("/sbin/route", ["-n", "get", "default"])
        async let dns = SystemCommand.run("/usr/sbin/scutil", ["--dns"])
        let routeOutput = await route.output
        gateway = Self.value(of: "gateway", in: routeOutput)
        defaultInterface = Self.value(of: "interface", in: routeOutput)
        dnsServers = Self.parseDNS(await dns.output)

        // Interface par défaut en premier, puis les autres, les tunnels à la fin
        interfaces = found.sorted { lhs, rhs in
            if lhs.device == defaultInterface { return true }
            if rhs.device == defaultInterface { return false }
            if lhs.isVPN != rhs.isVPN { return !lhs.isVPN }
            return lhs.device.localizedStandardCompare(rhs.device) == .orderedAscending
        }
    }

    /// Interroge ipify.org (service public, sans compte) pour connaître l'adresse vue depuis Internet.
    func fetchPublicIP() async {
        isFetchingPublicIP = true
        defer { isFetchingPublicIP = false }
        async let v4 = Self.fetch("https://api.ipify.org")
        async let v6 = Self.fetch("https://api6.ipify.org")
        publicIPv4 = await v4
        let six = await v6
        // api6 renvoie l'IPv4 quand il n'y a pas de connectivité IPv6
        publicIPv6 = six?.contains(":") == true ? six : nil
        if publicIPv4 == nil && publicIPv6 == nil { message = String(localized: "IP publique introuvable (pas de connexion Internet ?)") }
    }

    /// Vide le cache DNS de macOS (droits administrateur, Touch ID si activé pour sudo).
    func flushDNS() async {
        do {
            _ = try await PrivilegedShell.run("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
            message = String(localized: "Cache DNS vidé.")
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: - Lecture

    private static func readInterfaces() -> [NetworkInterface] {
        var result: [String: NetworkInterface] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var ip = String(cString: host)
            // « fe80::1%en0 » : on retire le suffixe d'interface
            if let percent = ip.firstIndex(of: "%") { ip = String(ip[..<percent]) }

            let device = String(cString: entry.pointee.ifa_name)
            var interface = result[device] ?? NetworkInterface(device: device)
            if family == AF_INET {
                interface.ipv4.append(ip)
            } else if !ip.hasPrefix("fe80") {
                // Les adresses de lien local IPv6 (fe80::) ne servent qu'au réseau local immédiat
                interface.ipv6.append(ip)
            }
            result[device] = interface
        }
        return result.values.filter { !$0.ipv4.isEmpty || !$0.ipv6.isEmpty }
    }

    /// « Hardware Port: Wi-Fi » suivi de « Device: en0 ».
    private static func parseHardwarePorts(_ output: String) -> [String: String] {
        var ports: [String: String] = [:]
        var currentPort: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { currentPort = String(line.dropFirst(15)) }
            if line.hasPrefix("Device: "), let port = currentPort { ports[String(line.dropFirst(8))] = port }
        }
        return ports
    }

    private static func value(of key: String, in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Serveurs DNS de `scutil --dns`, sans doublons, dans l'ordre (« nameserver[0] : 1.1.1.1 »).
    private static func parseDNS(_ output: String) -> [String] {
        var servers: [String] = []
        for line in output.split(separator: "\n") where line.contains("nameserver[") {
            guard let colon = line.lastIndex(of: ":") , line.contains(" : ") else { continue }
            let parts = line.components(separatedBy: " : ")
            let server = (parts.last ?? String(line[line.index(after: colon)...])).trimmingCharacters(in: .whitespaces)
            if !server.isEmpty && !servers.contains(server) { servers.append(server) }
        }
        return servers
    }

    private static func fetch(_ address: String) async -> String? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Diagnostic (terminal)

    static func pingCommand(_ host: String) -> String { Shell.join(["/sbin/ping", "-c", "5", host]) }
    static func tracerouteCommand(_ host: String) -> String { Shell.join(["/usr/sbin/traceroute", "-w", "2", "-q", "1", host]) }
    static func lookupCommand(_ host: String) -> String { Shell.join(["/usr/bin/dscacheutil", "-q", "host", "-a", "name", host]) }
}

// MARK: - /etc/hosts

/// Une ligne de /etc/hosts associant une adresse à des noms. Désactivée = commentée (« # »).
struct HostsEntry: Identifiable, Equatable {
    let id = UUID()
    var address: String
    var names: String
    var comment: String
    var enabled: Bool

    /// Entrées par défaut de macOS : à ne pas modifier.
    var isSystem: Bool {
        let list = names.split(separator: " ").map(String.init)
        return list.contains("localhost") || list.contains("broadcasthost")
    }

    var isValid: Bool {
        HostsFile.isIPAddress(address.trimmingCharacters(in: .whitespaces))
            && !names.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func line() -> String {
        var line = (enabled ? "" : "#") + address.trimmingCharacters(in: .whitespaces) + "\t"
            + names.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let note = comment.trimmingCharacters(in: .whitespaces)
        if !note.isEmpty { line += "\t# " + note }
        return line
    }
}

/// /etc/hosts découpé en lignes : les entrées sont modifiables, le reste est conservé tel quel.
struct HostsFile: Equatable {
    enum Line: Equatable {
        case raw(String)
        /// Entrée, avec sa ligne d'origine (réécrite à l'identique si l'entrée n'a pas changé).
        case entry(HostsEntry, original: String?)
    }

    var lines: [Line]

    static let url = URL(fileURLWithPath: "/etc/hosts")

    var entries: [HostsEntry] {
        lines.compactMap { if case .entry(let entry, _) = $0 { entry } else { nil } }
    }

    static func parse(_ text: String) -> HostsFile {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return HostsFile(lines: lines.map { line -> Line in
            if let entry = parseEntry(line) { return .entry(entry, original: line) }
            return .raw(line)
        })
    }

    private static func parseEntry(_ line: String) -> HostsEntry? {
        var body = line.trimmingCharacters(in: .whitespaces)
        var enabled = true
        if body.hasPrefix("#") {
            enabled = false
            body = String(body.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        }
        var comment = ""
        if let hash = body.firstIndex(of: "#") {
            comment = String(body[body.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            body = String(body[..<hash])
        }
        let fields = body.split(whereSeparator: \.isWhitespace).map(String.init)
        // Un commentaire ordinaire ne commence pas par une adresse IP
        guard fields.count >= 2, isIPAddress(fields[0]) else { return nil }
        return HostsEntry(address: fields[0], names: fields.dropFirst().joined(separator: " "),
                          comment: comment, enabled: enabled)
    }

    static func isIPAddress(_ text: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    func serialized() -> String {
        lines.map { line -> String in
            switch line {
            case .raw(let text): return text
            case .entry(let entry, let original):
                if let original, HostsFile.parseEntry(original).map({ same($0, entry) }) == true { return original }
                return entry.line()
            }
        }
        .joined(separator: "\n") + "\n"
    }

    /// Même contenu (l'identifiant change à chaque lecture).
    private func same(_ a: HostsEntry, _ b: HostsEntry) -> Bool {
        a.address == b.address && a.names == b.names && a.comment == b.comment && a.enabled == b.enabled
    }

    mutating func update(_ entry: HostsEntry) {
        guard let index = lines.firstIndex(where: { if case .entry(let e, _) = $0 { e.id == entry.id } else { false } }),
              case .entry(_, let original) = lines[index] else { return }
        lines[index] = .entry(entry, original: original)
    }

    mutating func add(_ entry: HostsEntry) {
        lines.append(.entry(entry, original: nil))
    }

    mutating func remove(_ id: HostsEntry.ID) {
        lines.removeAll { if case .entry(let e, _) = $0 { e.id == id } else { false } }
    }
}

@MainActor
@Observable
final class HostsStore {
    private(set) var file = HostsFile(lines: [])
    private var original = HostsFile(lines: [])
    private(set) var message: String?

    var hasChanges: Bool { file.serialized() != original.serialized() }

    func reload() {
        let text = (try? String(contentsOf: HostsFile.url, encoding: .utf8)) ?? ""
        file = HostsFile.parse(text)
        original = file
    }

    func update(_ entry: HostsEntry) { file.update(entry) }
    func add(_ entry: HostsEntry) { file.add(entry) }
    func remove(_ id: HostsEntry.ID) { file.remove(id) }
    func discard() { file = original }

    /// Remplace tout le contenu (mode texte).
    func setText(_ text: String) { file = HostsFile.parse(text) }

    /// Écrit /etc/hosts avec les droits administrateur, après une copie de secours,
    /// puis vide le cache DNS pour que les changements prennent effet tout de suite.
    func save() async {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("octopus-hosts")
        do {
            try file.serialized().write(to: temporary, atomically: true, encoding: .utf8)
            _ = try await PrivilegedShell.run([
                "/bin/cp /etc/hosts /etc/hosts.octopus-backup",
                // « cat > » garde le propriétaire et les permissions du fichier
                "/bin/cat \(Shell.quote(temporary.path)) > /etc/hosts",
                "/usr/bin/dscacheutil -flushcache",
                "/usr/bin/killall -HUP mDNSResponder",
            ].joined(separator: " && "))
            message = String(localized: "Enregistré (copie de l'ancien fichier : /etc/hosts.octopus-backup) et cache DNS vidé.")
            reload()
        } catch {
            message = error.localizedDescription
        }
        try? FileManager.default.removeItem(at: temporary)
    }
}
