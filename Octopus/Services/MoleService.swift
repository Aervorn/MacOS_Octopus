import Foundation
import Observation

/// Tout ce que l'app sait de l'installation de Mole : où est `mo`, sa version,
/// comment il a été installé et s'il existe une version plus récente.
@MainActor
@Observable
final class MoleService {
    enum InstallMethod: Equatable {
        /// Installé avec `brew install mole` : se met à jour avec `brew upgrade mole`.
        case homebrew(brew: String)
        /// Installé avec le script officiel : se met à jour avec `mo update`.
        case script
    }

    enum State: Equatable {
        case checking
        case missing
        case installed(path: String, version: String?, method: InstallMethod)
    }

    private(set) var state: State = .checking
    /// Dernière version publiée sur GitHub (`nil` tant qu'on ne la connaît pas).
    private(set) var latestVersion: String?

    var executablePath: String? {
        if case .installed(let path, _, _) = state { path } else { nil }
    }

    var installedVersion: String? {
        if case .installed(_, let version, _) = state { version } else { nil }
    }

    var updateAvailable: Bool {
        guard let installed = installedVersion, let latest = latestVersion else { return false }
        return latest.compare(installed, options: .numeric) == .orderedDescending
    }

    /// Recherche `mo`, lit sa version, puis interroge GitHub. Rapide, sans effet de bord.
    /// `checkLatest: false` évite l'appel à GitHub (limité à 60 requêtes par heure sans compte).
    func refresh(checkLatest: Bool = true) async {
        guard let path = await Self.locate() else {
            state = .missing
            return
        }
        let version = await Self.version(of: path)
        state = .installed(path: path, version: version, method: Self.installMethod(of: path))
        if checkLatest || latestVersion == nil {
            latestVersion = await Self.fetchLatestRelease()
        }
    }

    // MARK: - Commandes à lancer dans le terminal

    /// Commande zsh de mise à jour, adaptée à la façon dont Mole est installé.
    func updateCommand(arguments: [String]) -> String? {
        guard case .installed(let path, _, let method) = state else { return nil }
        switch method {
        case .homebrew(let brew):
            // Les options de `mo update` (--nightly, --force) n'ont pas d'équivalent Homebrew.
            return "\(Shell.quote(brew)) update && \(Shell.quote(brew)) upgrade mole"
        case .script:
            return Shell.join([path] + arguments)
        }
    }

    /// Commande zsh d'installation de Mole, via Homebrew s'il est présent.
    static func installCommand() -> String {
        if let brew = homebrewCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return "\(Shell.quote(brew)) install mole"
        }
        return "curl -fsSL https://raw.githubusercontent.com/tw93/mole/main/install.sh | bash"
    }

    // MARK: - Détection

    private static let homebrewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    /// Une app lancée depuis le Finder n'hérite pas du PATH du shell : on essaie d'abord
    /// les emplacements connus, puis on demande à un zsh de connexion.
    private static func locate() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/mo",
            "/usr/local/bin/mo",
            "\(home)/.local/bin/mo",
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let output = await run("/bin/zsh", ["-l", "-c", "command -v mo"])
        let path = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Le binaire Homebrew est un lien vers `…/Cellar/mole/<version>/…`.
    private static func installMethod(of path: String) -> InstallMethod {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if resolved.contains("/Cellar/") {
            let prefix = resolved.components(separatedBy: "/Cellar/").first ?? "/opt/homebrew"
            return .homebrew(brew: "\(prefix)/bin/brew")
        }
        return .script
    }

    /// Premier numéro de version trouvé dans la sortie de `mo --version`.
    private static func version(of path: String) async -> String? {
        guard let output = await run(path, ["--version"], environment: ["NO_COLOR": "1"]) else { return nil }
        return firstVersion(in: output)
    }

    static func firstVersion(in text: String) -> String? {
        guard let range = text.range(of: #"\d+\.\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Tag de la dernière version publiée (« V1.51.0 » → « 1.51.0 »).
    private static func fetchLatestRelease() async -> String? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/tw93/Mole/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Octopus", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        struct Release: Decodable { let tag_name: String }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let release = try? JSONDecoder().decode(Release.self, from: data) else { return nil }
        return firstVersion(in: release.tag_name)
    }

    // MARK: - Exécution simple (sans terminal)

    /// Lance un programme et renvoie sa sortie standard, ou `nil` en cas d'échec.
    /// Pour les commandes courtes et non interactives uniquement : la sortie n'est lue
    /// qu'à la fin, une sortie de plus de 64 Ko bloquerait le processus.
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8)
                continuation.resume(returning: process.terminationStatus == 0 ? text : nil)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
