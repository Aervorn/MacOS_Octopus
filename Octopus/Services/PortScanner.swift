import AppKit
import Darwin
import Foundation
import Observation

/// Un port TCP en écoute et le processus qui le tient.
struct ListeningPort: Identifiable, Equatable {
    let port: Int
    let pid: Int32
    let processName: String
    let user: String?
    /// Adresses d'écoute : « * » (toutes), « 127.0.0.1 », « [::1] »…
    var addresses: [String]
    /// Chemin complet de l'exécutable.
    var executablePath: String? = nil
    /// Ligne de commande complète (« node /…/server.js --port 3000 »).
    var commandLine: String? = nil

    /// Ligne de commande avec ~ pour le dossier personnel, plus lisible.
    var displayCommand: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (commandLine ?? executablePath ?? processName).replacingOccurrences(of: home, with: "~")
    }

    var id: String { "\(pid)-\(port)" }

    /// N'écoute que sur la boucle locale : inaccessible depuis le réseau.
    var isLocalOnly: Bool {
        addresses.allSatisfy { ["127.0.0.1", "[::1]", "localhost"].contains($0) }
    }

    var addressSummary: String {
        if addresses.contains("*") || addresses.contains("[::]") || addresses.contains("0.0.0.0") {
            return "Toutes les interfaces"
        }
        return isLocalOnly ? "Local uniquement" : addresses.joined(separator: ", ")
    }

    /// Port connu, pour donner une idée de ce que c'est.
    var wellKnownService: String? {
        switch port {
        case 22: "SSH"
        case 80, 8080, 8000, 8888: "HTTP"
        case 443, 8443: "HTTPS"
        case 3000, 3001, 4200, 5173, 5174, 8081: "Serveur de dev"
        case 3306: "MySQL"
        case 5432: "PostgreSQL"
        case 6379: "Redis"
        case 27017: "MongoDB"
        case 5000, 7000: "AirPlay"
        case 5900: "Partage d'écran"
        case 445: "Partage de fichiers"
        case 631: "Impression"
        case 11434: "Ollama"
        default: nil
        }
    }
}

/// Liste les ports TCP en écoute avec `lsof`.
///
/// Sans droits administrateur, `lsof` ne voit que les processus de l'utilisateur :
/// les services du système (lancés par root) n'apparaissent pas.
@MainActor
@Observable
final class PortScanner {
    private(set) var ports: [ListeningPort] = []
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    private(set) var message: String?
    /// Inclure les processus des autres utilisateurs et du système (demande les droits administrateur).
    var includeSystem = false {
        didSet { if !includeSystem { message = nil } }
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        var found: [ListeningPort]
        var commands: [Int32: String] = [:]

        if includeSystem {
            // Une seule autorisation pour lsof et ps ; « true » car lsof renvoie 1 s'il ne trouve rien
            let separator = "__OCTOPUS_PS__"
            do {
                let output = try await PrivilegedShell.run(
                    "/usr/sbin/lsof -nP -iTCP -sTCP:LISTEN -F pcLn; echo \(separator); /bin/ps -ww -A -o pid=,args=; true")
                let parts = output.components(separatedBy: separator)
                found = Self.parse(parts[0])
                commands = Self.parseCommands(parts.count > 1 ? parts[1] : "")
            } catch {
                includeSystem = false
                message = error.localizedDescription
                return
            }
        } else {
            // -F : sortie « un champ par ligne » facile à lire ; -n -P : ni DNS ni noms de ports
            let result = await SystemCommand.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcLn"])
            // lsof renvoie 1 quand il ne trouve rien : ce n'est pas une erreur
            found = Self.parse(result.output)
            // Lignes de commande de tous les processus trouvés, en un seul appel à ps
            let pids = Set(found.map(\.pid))
            if !pids.isEmpty {
                let list = pids.map(String.init).joined(separator: ",")
                let ps = await SystemCommand.run("/bin/ps", ["-ww", "-o", "pid=,args=", "-p", list])
                commands = Self.parseCommands(ps.output)
            }
        }

        for index in found.indices {
            let command = commands[found[index].pid]
            found[index].commandLine = command
            // proc_pidpath échoue pour les processus root : on prend alors le début de la commande
            found[index].executablePath = Self.executablePath(for: found[index].pid)
                ?? command.flatMap { $0.hasPrefix("/") ? String($0.split(separator: " ").first ?? "") : nil }
        }
        ports = found
        lastScan = .now
    }

    /// Analyse la sortie `-F pcLn` :
    ///   p1234 / cnode / Lyohan / f23 / n*:3000 / f24 / n[::1]:3000 / p…
    static func parse(_ output: String) -> [ListeningPort] {
        var byKey: [String: ListeningPort] = [:]
        var pid: Int32 = 0
        var command = ""
        var user: String?

        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value) ?? 0
                command = ""
                user = nil
            case "c": command = value
            case "L": user = value
            case "n":
                guard let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let address = String(value[..<colon])
                let key = "\(pid)-\(port)"
                if byKey[key] == nil {
                    byKey[key] = ListeningPort(port: port, pid: pid, processName: command, user: user, addresses: [])
                }
                if !byKey[key]!.addresses.contains(address) {
                    byKey[key]!.addresses.append(address)
                }
            default:
                break
            }
        }
        return byKey.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// « 1234 /usr/bin/node server.js » → [1234: "/usr/bin/node server.js"]
    static func parseCommands(_ output: String) -> [Int32: String] {
        var commands: [Int32: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            commands[pid] = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
        }
        return commands
    }

    static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Processus

    /// Demande au processus de se fermer (SIGTERM), ou le force (SIGKILL).
    func stop(_ port: ListeningPort, force: Bool) async {
        // Processus d'un autre utilisateur (root) : kill avec les droits administrateur
        if port.user != nil && port.user != NSUserName() {
            do {
                _ = try await PrivilegedShell.run("/bin/kill -\(force ? "KILL" : "TERM") \(port.pid)")
                message = "\(port.processName) (PID \(port.pid)) : arrêt demandé avec les droits administrateur."
            } catch {
                message = "Impossible d'arrêter \(port.processName) : \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .milliseconds(600))
            await scan()
            return
        }
        if Darwin.kill(port.pid, force ? SIGKILL : SIGTERM) == 0 {
            message = force
                ? "\(port.processName) (PID \(port.pid)) a été arrêté de force."
                : "Demande d'arrêt envoyée à \(port.processName) (PID \(port.pid))."
        } else {
            let reason = errno == EPERM
                ? "il appartient à un autre utilisateur"
                : String(cString: strerror(errno))
            message = "Impossible d'arrêter \(port.processName) : \(reason)."
        }
        try? await Task.sleep(for: .milliseconds(600))
        await scan()
    }

    /// Icône et chemin de l'app ou de l'exécutable, si on les trouve.
    static func appInfo(for pid: Int32) -> (icon: NSImage?, path: String?) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return (app.icon, app.bundleURL?.path ?? app.executableURL?.path)
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return (nil, nil) }
        let path = String(cString: buffer)
        return (NSWorkspace.shared.icon(forFile: path), path)
    }

    static func sudoListCommand() -> String {
        "sudo /usr/sbin/lsof -nP -iTCP -sTCP:LISTEN"
    }
}
