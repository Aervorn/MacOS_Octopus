import Foundation
import Observation

/// Paquet installé : formule (outil en ligne de commande) ou cask (app).
struct BrewPackage: Identifiable, Equatable {
    enum Kind: String { case formula = "Formule", cask = "App (cask)" }

    let name: String
    let kind: Kind
    let version: String
    let description: String?
    let homepage: String?
    /// Installé explicitement (sinon : dépendance d'un autre paquet).
    let onRequest: Bool
    let pinned: Bool
    let outdated: Bool
    /// L'app se met à jour toute seule (casks) : brew ne la met pas à jour par défaut.
    let autoUpdates: Bool
    let installedOn: Date?
    /// Apps installées par le cask (« WhatsApp.app »…).
    var appNames: [String] = []

    var id: String { "\(kind.rawValue):\(name)" }
    var kindRank: Int { kind == .formula ? 0 : 1 }
    var requestRank: Int { onRequest ? 0 : 1 }
    var descriptionText: String { description ?? "" }
    var installedSort: Date { installedOn ?? .distantPast }
}

/// Mise à jour disponible.
struct BrewOutdated: Identifiable, Equatable {
    let name: String
    let kind: BrewPackage.Kind
    let installed: String
    let available: String
    let pinned: Bool

    var id: String { "\(kind.rawValue):\(name)" }
}

/// Mise à jour de cask bloquée par une ancienne copie de l'app restée dans le Caskroom.
///
/// Pour mettre à jour un cask, Homebrew met l'ancienne app de côté dans
/// Caskroom/<cask>/<version>/. Si une tentative précédente a été interrompue, une copie
/// y est déjà : Homebrew refuse de l'écraser (« It seems there is already an App at… »)
/// et chaque nouvelle mise à jour échoue au même endroit.
struct StuckCask: Identifiable, Equatable {
    let cask: String
    let appName: String
    /// Copie de sauvegarde à retirer.
    let leftoverPath: String
    /// App réellement utilisée, qui reste en place.
    let installedPath: String

    var id: String { leftoverPath }
}

/// Service géré par `brew services` (launchd).
struct BrewService: Identifiable, Equatable {
    let name: String
    let status: String
    let user: String?
    let file: String?
    let exitCode: Int?

    var id: String { name }
    var isRunning: Bool { status == "started" || status == "scheduled" }

    var statusTitle: String {
        switch status {
        case "started": "En cours"
        case "scheduled": "Planifié"
        case "stopped": "Arrêté"
        case "none": "Non lancé"
        case "error": "Erreur" + (exitCode.map { " (code \($0))" } ?? "")
        default: status
        }
    }
}

/// Lit l'état de Homebrew avec ses sorties JSON.
@MainActor
@Observable
final class HomebrewStore {
    /// Connu dès la création : évite d'afficher « non installé » le temps du premier chargement.
    private(set) var brewPath: String? = HomebrewStore.locate()
    private(set) var packages: [BrewPackage] = []
    private(set) var outdated: [BrewOutdated] = []
    private(set) var services: [BrewService] = []
    private(set) var stuckCasks: [StuckCask] = []
    private(set) var cleanupEstimate: String?
    private(set) var autoremoveCandidates: [String] = []
    private(set) var isLoading = false
    private(set) var isUpdatingIndex = false
    private(set) var lastIndexUpdate: Date?
    private(set) var message: String?

    var isInstalled: Bool { brewPath != nil }

    static func locate() -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Environnement pour brew : pas de mise à jour automatique ni de couleurs, PATH complet.
    private var environment: [String: String] {
        let prefix = brewPath.map { ($0 as NSString).deletingLastPathComponent } ?? "/opt/homebrew/bin"
        return [
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_COLOR": "1",
            "NO_COLOR": "1",
            "PATH": "\(prefix):/usr/bin:/bin:/usr/sbin:/sbin",
        ]
    }

    private func brew(_ arguments: [String]) async -> SystemCommand.Result {
        guard let brewPath else { return SystemCommand.Result(status: -1, output: "") }
        return await SystemCommand.run(brewPath, arguments, environment: environment)
    }

    func reload() async {
        brewPath = Self.locate()
        guard brewPath != nil else { return }
        isLoading = true
        defer { isLoading = false }

        async let info = brew(["info", "--json=v2", "--installed"])
        async let outdatedResult = brew(["outdated", "--json=v2"])
        async let servicesResult = brew(["services", "list", "--json"])

        packages = Self.parsePackages(Self.json(in: await info.output))
        outdated = Self.parseOutdated(Self.json(in: await outdatedResult.output))
        services = Self.parseServices(Self.json(in: await servicesResult.output))
        stuckCasks = findStuckCasks()
    }

    /// `brew update` : télécharge la liste des dernières versions (quelques secondes à une minute).
    func updateIndex() async {
        isUpdatingIndex = true
        defer { isUpdatingIndex = false }
        let result = await brew(["update"])
        message = result.succeeded ? nil : "brew update a échoué : " + (result.output.split(separator: "\n").last.map(String.init) ?? "")
        lastIndexUpdate = .now
        await reload()
    }

    /// Ce que `brew cleanup` et `brew autoremove` libéreraient, sans rien supprimer.
    func checkMaintenance() async {
        async let cleanup = brew(["cleanup", "-n"])
        async let autoremove = brew(["autoremove", "-n"])

        let cleanupOutput = await cleanup.output
        if let line = cleanupOutput.split(separator: "\n").first(where: { $0.contains("would free approximately") }),
           let range = line.range(of: "approximately ") {
            cleanupEstimate = line[range.upperBound...]
                .replacingOccurrences(of: " of disk space.", with: "")
                .trimmingCharacters(in: .whitespaces)
        } else {
            cleanupEstimate = "rien"
        }

        // « ==> Would autoremove 3 unneeded formulae: » puis un nom par ligne
        let lines = await autoremove.output.split(separator: "\n").map(String.init)
        if let start = lines.firstIndex(where: { $0.contains("Would autoremove") }) {
            autoremoveCandidates = lines[(start + 1)...]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("==>") }
        } else {
            autoremoveCandidates = []
        }
    }

    func service(_ service: BrewService, action: String) async {
        let result = await brew(["services", action, service.name])
        message = result.succeeded
            ? nil
            : result.output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
        await reload()
    }

    // MARK: - Mises à jour bloquées

    /// Préfixe de Homebrew : /opt/homebrew (Apple Silicon) ou /usr/local (Intel).
    private var prefix: String? {
        brewPath.map { (($0 as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent }
    }

    /// Une app présente à la fois dans le Caskroom et dans /Applications : la copie du
    /// Caskroom est un reste de mise à jour interrompue. Normalement, Homebrew y déplace
    /// l'app seulement le temps de la mise à jour.
    private func findStuckCasks() -> [StuckCask] {
        guard let prefix else { return [] }
        let fm = FileManager.default
        var stuck: [StuckCask] = []
        for package in packages where package.kind == .cask {
            for app in package.appNames {
                let leftover = "\(prefix)/Caskroom/\(package.name)/\(package.version)/\(app)"
                let installed = "/Applications/\(app)"
                var isDirectory: ObjCBool = false
                let leftoverIsRealApp = fm.fileExists(atPath: leftover, isDirectory: &isDirectory)
                    && isDirectory.boolValue
                    && (try? fm.destinationOfSymbolicLink(atPath: leftover)) == nil
                if leftoverIsRealApp && fm.fileExists(atPath: installed) {
                    stuck.append(StuckCask(cask: package.name, appName: app, leftoverPath: leftover, installedPath: installed))
                }
            }
        }
        return stuck
    }

    /// Met la copie bloquante à la Corbeille (récupérable), sans toucher à l'app installée.
    func repair(_ stuck: StuckCask) async -> Bool {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: stuck.leftoverPath), resultingItemURL: nil)
            message = nil
            await reload()
            return true
        } catch {
            message = "Réparation impossible : \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Commandes pour le terminal

    func command(_ arguments: [String]) -> String {
        let env = "HOMEBREW_NO_ENV_HINTS=1"
        return env + " " + Shell.join([brewPath ?? "brew"] + arguments)
    }

    func upgradeCommand(_ items: [BrewOutdated]) -> String {
        let formulae = items.filter { $0.kind == .formula }.map(\.name)
        let casks = items.filter { $0.kind == .cask }.map(\.name)
        var parts: [String] = []
        if !formulae.isEmpty { parts.append(command(["upgrade", "--formula"] + formulae)) }
        if !casks.isEmpty { parts.append(command(["upgrade", "--cask"] + casks)) }
        return parts.joined(separator: " && ")
    }

    static let installCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    // MARK: - Analyse

    /// Les sorties JSON peuvent être précédées d'avertissements : on part de la première accolade ou du premier crochet.
    private static func json(in output: String) -> Any? {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let data = String(output[start...]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func parsePackages(_ json: Any?) -> [BrewPackage] {
        guard let root = json as? [String: Any] else { return [] }
        var result: [BrewPackage] = []
        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            let installed = (formula["installed"] as? [[String: Any]])?.last
            result.append(BrewPackage(
                name: formula["name"] as? String ?? "?",
                kind: .formula,
                version: installed?["version"] as? String ?? "?",
                description: formula["desc"] as? String,
                homepage: formula["homepage"] as? String,
                onRequest: installed?["installed_on_request"] as? Bool ?? true,
                pinned: formula["pinned"] as? Bool ?? false,
                outdated: formula["outdated"] as? Bool ?? false,
                autoUpdates: false,
                installedOn: (installed?["time"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ))
        }
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            let names = cask["name"] as? [String]
            // artifacts : [{"app": ["WhatsApp.app"]}, {"zap": …}, …]
            let apps = (cask["artifacts"] as? [[String: Any]] ?? []).flatMap { artifact -> [String] in
                (artifact["app"] as? [Any] ?? []).compactMap { $0 as? String }
            }
            var package = BrewPackage(
                name: cask["token"] as? String ?? "?",
                kind: .cask,
                version: cask["installed"] as? String ?? cask["version"] as? String ?? "?",
                description: cask["desc"] as? String ?? names?.first,
                homepage: cask["homepage"] as? String,
                onRequest: true,
                pinned: false,
                outdated: cask["outdated"] as? Bool ?? false,
                autoUpdates: cask["auto_updates"] as? Bool ?? false,
                installedOn: (cask["installed_time"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
            package.appNames = apps
            result.append(package)
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func parseOutdated(_ json: Any?) -> [BrewOutdated] {
        guard let root = json as? [String: Any] else { return [] }
        func versions(_ value: Any?) -> String {
            if let list = value as? [String] { return list.joined(separator: ", ") }
            return value as? String ?? "?"
        }
        var result: [BrewOutdated] = []
        for formula in root["formulae"] as? [[String: Any]] ?? [] {
            result.append(BrewOutdated(
                name: formula["name"] as? String ?? "?", kind: .formula,
                installed: versions(formula["installed_versions"]),
                available: formula["current_version"] as? String ?? "?",
                pinned: formula["pinned"] as? Bool ?? false))
        }
        for cask in root["casks"] as? [[String: Any]] ?? [] {
            result.append(BrewOutdated(
                name: cask["name"] as? String ?? "?", kind: .cask,
                installed: versions(cask["installed_versions"]),
                available: cask["current_version"] as? String ?? "?",
                pinned: false))
        }
        return result
    }

    private static func parseServices(_ json: Any?) -> [BrewService] {
        guard let list = json as? [[String: Any]] else { return [] }
        return list.map { item in
            BrewService(
                name: item["name"] as? String ?? "?",
                status: item["status"] as? String ?? "none",
                user: item["user"] as? String,
                file: item["file"] as? String,
                exitCode: item["exit_code"] as? Int)
        }
    }
}
