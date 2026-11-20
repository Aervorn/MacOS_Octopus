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

/// Cask dont l'app installée n'a pas la version que Homebrew a notée : l'app a été
/// mise à jour sans lui (DMG installé à la main, mise à jour intégrée à l'app…).
struct BrewDrift: Identifiable, Equatable {
    /// Même identifiant que le paquet (« App (cask):trilium-notes »).
    let id: String
    let cask: String
    let appPath: String
    /// Version notée par Homebrew dans son Caskroom.
    let recorded: String
    /// Version réelle de l'app (Info.plist).
    let actual: String
    /// Dernière version du cask, si Homebrew propose une mise à jour.
    let latest: String?
    let autoUpdates: Bool
    /// L'app est déjà à la dernière version : seul le registre de Homebrew est en retard.
    let isCurrent: Bool
}

/// App installée hors Homebrew alors qu'un cask existe pour elle.
struct AdoptableApp: Identifiable, Equatable {
    let path: String
    let name: String
    let version: String
    let cask: String
    let caskVersion: String
    /// Même version que le cask : Homebrew peut l'adopter sans rien retélécharger.
    let versionMatches: Bool

    var id: String { path }
}

/// Même app (même identifiant de bundle) présente à plusieurs endroits.
struct DuplicateApp: Identifiable, Equatable {
    struct Copy: Identifiable, Equatable {
        let path: String
        let version: String
        /// Cask qui gère cette copie, s'il y en a un.
        let cask: String?

        var id: String { path }
    }

    let bundleID: String
    let copies: [Copy]

    var id: String { bundleID }
    var name: String { copies.first.map { ($0.path as NSString).lastPathComponent } ?? bundleID }
}

/// Infos d'une app lues dans son Info.plist.
struct AppBundle: Equatable {
    let path: String
    let bundleID: String?
    let shortVersion: String?
    let buildVersion: String?
    /// Installée depuis le Mac App Store (reçu dans le bundle).
    let fromAppStore: Bool

    var name: String { (path as NSString).lastPathComponent }
    var displayVersion: String { shortVersion ?? buildVersion ?? "?" }

    static func read(_ path: String) -> AppBundle? {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any] else { return nil }
        return AppBundle(
            path: path,
            bundleID: info["CFBundleIdentifier"] as? String,
            shortVersion: (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespaces),
            buildVersion: (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespaces),
            fromAppStore: FileManager.default.fileExists(atPath: path + "/Contents/_MASReceipt"))
    }

    /// Dossiers où cherche les apps installées : ceux où les casks les mettent.
    static var roots: [String] { ["/Applications", NSHomeDirectory() + "/Applications"] }

    /// Emplacement réel d'une app de cask (« WhatsApp.app »), dans /Applications ou ~/Applications.
    static func installedPath(for appName: String) -> String? {
        let file = (appName as NSString).lastPathComponent
        return roots.map { ($0 as NSString).appendingPathComponent(file) }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Toutes les apps de /Applications et ~/Applications, plus un niveau de sous-dossier
    /// (« /Applications/Utilities », dossiers d'éditeurs…). Les liens symboliques sont ignorés :
    /// ils pointent vers une app déjà comptée ailleurs.
    static func scanInstalled() -> [AppBundle] {
        let fm = FileManager.default
        var result: [AppBundle] = []

        func isSymlink(_ path: String) -> Bool {
            (try? fm.destinationOfSymbolicLink(atPath: path)) != nil
        }

        func scan(_ directory: String, depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: directory) else { return }
            for name in names where !name.hasPrefix(".") {
                let path = (directory as NSString).appendingPathComponent(name)
                guard !isSymlink(path) else { continue }
                if name.hasSuffix(".app") {
                    if let bundle = read(path) { result.append(bundle) }
                } else if depth == 0 {
                    var isDirectory: ObjCBool = false
                    if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                        scan(path, depth: 1)
                    }
                }
            }
        }

        roots.forEach { scan($0, depth: 0) }
        return result
    }

    /// Vrai si l'une des versions de l'app correspond à la version d'un cask.
    func matches(_ caskVersion: String) -> Bool {
        [shortVersion, buildVersion].compactMap { $0 }.contains { VersionMatch.same($0, caskVersion) }
    }
}

/// Compare une version d'app et une version de cask, qui ne s'écrivent pas toujours pareil
/// (« 1.2.3,4567 » côté cask, « 1.2.3 » et « 4567 » côté app, « v2.0 », « 2.0.0 »…).
enum VersionMatch {
    static func same(_ appVersion: String, _ caskVersion: String) -> Bool {
        let candidates = [caskVersion] + caskVersion.split(separator: ",").map(String.init)
        let app = numbers(appVersion)
        return candidates.contains { candidate in
            let cask = numbers(candidate)
            guard !app.isEmpty, !cask.isEmpty else { return appVersion == candidate }
            if app == cask { return true }
            // « 2.25.20 » contre « 2.25.20.80 » : on accepte si au moins trois numéros concordent.
            return min(app.count, cask.count) >= 3 && (app.starts(with: cask) || cask.starts(with: app))
        }
    }

    /// L'app est plus récente que le cask (bêta, version installée à la main…).
    static func isNewer(_ appVersion: String, than caskVersion: String) -> Bool {
        let app = numbers(appVersion)
        let cask = numbers(caskVersion.split(separator: ",").first.map(String.init) ?? caskVersion)
        guard !app.isEmpty, !cask.isEmpty else { return false }
        return app.lexicographicallyPrecedes(cask) == false && app != cask
            && !(min(app.count, cask.count) >= 3 && (app.starts(with: cask) || cask.starts(with: app)))
    }

    /// « v1.2.0 (45) » → [1, 2, 0, 45] ; zéros finaux retirés pour que « 2.0 » vaille « 2 ».
    private static func numbers(_ version: String) -> [Int] {
        var parts = version.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }
}

/// Catalogue de tous les casks, lu dans le cache de l'API Homebrew (rempli par `brew update`).
enum CaskCatalog {
    struct Entry {
        let token: String
        let version: String
    }

    /// Nom de l'app (« Firefox.app ») → casks qui l'installent.
    ///
    /// Deux formats selon la version de Homebrew :
    /// - récent : api/internal/packages.<système>.jws.json, casks rangés par nom, apps dans
    ///   « raw_artifacts » ([":app", ["Firefox.app"]]) ;
    /// - ancien : api/cask.jws.json, liste de casks, apps dans « artifacts » ([{"app": [...]}]).
    static func load(cacheDirectory: String) -> [String: [Entry]]? {
        let api = URL(fileURLWithPath: cacheDirectory).appendingPathComponent("api")
        var catalog: [String: [Entry]] = [:]

        func add(token: String, cask: [String: Any], apps: [String]) {
            let version = cask["version"] as? String ?? "?"
            for app in apps {
                catalog[(app as NSString).lastPathComponent, default: []].append(Entry(token: token, version: version))
            }
        }

        if let file = latestPackagesFile(in: api.appendingPathComponent("internal")),
           let payload = decodedPayload(of: file) as? [String: Any],
           let casks = payload["casks"] as? [String: [String: Any]] {
            for (token, cask) in casks {
                let apps = (cask["raw_artifacts"] as? [[Any]] ?? []).flatMap { artifact -> [String] in
                    guard artifact.first as? String == ":app", artifact.count > 1 else { return [] }
                    return (artifact[1] as? [Any] ?? []).compactMap { $0 as? String }
                }
                add(token: token, cask: cask, apps: apps)
            }
            return catalog
        }

        if let casks = decodedPayload(of: api.appendingPathComponent("cask.jws.json")) as? [[String: Any]] {
            for cask in casks {
                guard let token = cask["token"] as? String else { continue }
                let apps = (cask["artifacts"] as? [[String: Any]] ?? []).flatMap { artifact -> [String] in
                    (artifact["app"] as? [Any] ?? []).compactMap { $0 as? String }
                }
                add(token: token, cask: cask, apps: apps)
            }
            return catalog
        }
        return nil
    }

    /// Le plus récent des fichiers packages.*.jws.json (un par système, s'il y en a plusieurs).
    private static func latestPackagesFile(in directory: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("packages.") && $0.lastPathComponent.hasSuffix(".jws.json") }
            .max {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
    }

    /// Fichier JWS signé : le contenu utile est une chaîne JSON dans « payload ».
    private static func decodedPayload(of file: URL) -> Any? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = (root["payload"] as? String)?.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: payload)
    }
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
        case "started": String(localized: "En cours")
        case "scheduled": String(localized: "Planifié")
        case "stopped": String(localized: "Arrêté")
        case "none": String(localized: "Non lancé")
        case "error": exitCode.map { String(localized: "Erreur (code \($0))") } ?? "Erreur"
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

    // MARK: - Exclusions

    /// Paquets exclus des mises à jour (ex. une app qui se met à jour autrement, comme Mp3tag).
    private(set) var excluded: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: Prefs.brewExcluded) ?? [])

    func isExcluded(_ id: String) -> Bool { excluded.contains(id) }

    func setExcluded(_ id: String, _ value: Bool) {
        if value { excluded.insert(id) } else { excluded.remove(id) }
        UserDefaults.standard.set(excluded.sorted(), forKey: Prefs.brewExcluded)
    }

    /// Mises à jour proposées : sans les paquets exclus.
    var visibleOutdated: [BrewOutdated] { outdated.filter { !excluded.contains($0.id) } }

    /// Mises à jour masquées parce que le paquet est exclu.
    var excludedOutdated: [BrewOutdated] { outdated.filter { excluded.contains($0.id) } }

    /// L'app se met à jour toute seule : « Tout mettre à jour » la laisse de côté.
    func updatesItself(_ item: BrewOutdated) -> Bool {
        item.kind == .cask && package(for: item.id)?.autoUpdates == true
    }

    /// Ce que « Tout mettre à jour » met à jour : ni les paquets épinglés, ni les apps qui
    /// se mettent à jour seules (Homebrew les retéléchargerait pour rien).
    var upgradeAllItems: [BrewOutdated] {
        visibleOutdated.filter { !$0.pinned && !updatesItself($0) }
    }

    /// « Tout mettre à jour » : `brew upgrade`, ou la liste explicite s'il y a des paquets à écarter.
    var upgradeAllCommand: String {
        guard !excludedOutdated.isEmpty || visibleOutdated.contains(where: { updatesItself($0) }) else {
            return command(["upgrade"])
        }
        return upgradeCommand(upgradeAllItems)
    }

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
        drifts = computeDrifts()
    }

    /// `brew update` : télécharge la liste des dernières versions (quelques secondes à une minute).
    func updateIndex() async {
        isUpdatingIndex = true
        defer { isUpdatingIndex = false }
        let result = await brew(["update"])
        message = result.succeeded ? nil : String(localized: "brew update a échoué : ") + (result.output.split(separator: "\n").last.map(String.init) ?? "")
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
            message = String(localized: "Réparation impossible : \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Cohérence avec les apps réellement installées

    /// Casks dont l'app a une autre version que celle notée par Homebrew.
    private(set) var drifts: [BrewDrift] = []
    /// Apps installées à la main pour lesquelles un cask existe.
    private(set) var adoptable: [AdoptableApp] = []
    /// Apps présentes en plusieurs exemplaires.
    private(set) var duplicates: [DuplicateApp] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    /// Le catalogue des casks (cache de l'API Homebrew) n'a pas pu être lu.
    private(set) var catalogMissing = false

    func drift(for id: String) -> BrewDrift? { drifts.first { $0.id == id } }

    func package(for id: String) -> BrewPackage? { packages.first { $0.id == id } }

    /// Écarts à signaler : ceux des apps qui se mettent à jour seules sont normaux.
    var reportedDrifts: [BrewDrift] { drifts.filter { !$0.autoUpdates } }

    /// Nombre de points à regarder dans l'onglet Cohérence.
    var coherenceIssueCount: Int { reportedDrifts.count + adoptable.count + duplicates.count }

    /// Dossier de cache de Homebrew (téléchargements et catalogue de l'API).
    private var cacheDirectory: String {
        ProcessInfo.processInfo.environment["HOMEBREW_CACHE"] ?? NSHomeDirectory() + "/Library/Caches/Homebrew"
    }

    /// Compare la version notée par Homebrew avec celle de l'app réellement installée.
    private func computeDrifts() -> [BrewDrift] {
        packages.filter { $0.kind == .cask && $0.version != "latest" }.compactMap { package -> BrewDrift? in
            guard let path = package.appNames.lazy.compactMap({ AppBundle.installedPath(for: $0) }).first,
                  let bundle = AppBundle.read(path),
                  !bundle.matches(package.version)
            else { return nil }
            let latest = outdated.first { $0.id == package.id }?.available
            return BrewDrift(
                id: package.id, cask: package.name, appPath: path,
                recorded: package.version, actual: bundle.displayVersion, latest: latest,
                autoUpdates: package.autoUpdates,
                isCurrent: latest.map { bundle.matches($0) } ?? false)
        }
    }

    /// Cherche les apps installées hors Homebrew et les doublons (lecture du disque et du
    /// catalogue des casks, quelques secondes).
    func scanCoherence() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        // Emplacement de chaque app gérée par un cask → nom du cask.
        var managedPaths: [String: String] = [:]
        var managedNames = Set<String>()
        for package in packages where package.kind == .cask {
            for app in package.appNames {
                managedNames.insert((app as NSString).lastPathComponent)
                if let path = AppBundle.installedPath(for: app) { managedPaths[path] = package.name }
            }
        }
        let cache = cacheDirectory
        let (apps, catalog) = await Task.detached(priority: .userInitiated) {
            (AppBundle.scanInstalled(), CaskCatalog.load(cacheDirectory: cache))
        }.value

        // Doublons : même identifiant de bundle à plusieurs endroits.
        let groups = Dictionary(grouping: apps.filter { $0.bundleID != nil }, by: { $0.bundleID! })
        duplicates = groups.filter { $0.value.count > 1 }
            .map { id, copies in
                DuplicateApp(bundleID: id, copies: copies.map {
                    DuplicateApp.Copy(path: $0.path, version: $0.displayVersion, cask: managedPaths[$0.path])
                }.sorted { $0.path < $1.path })
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        // Apps installées à la main qu'un cask pourrait gérer. On écarte celles du Mac App
        // Store et d'Apple, que Homebrew ne doit pas reprendre.
        catalogMissing = catalog == nil
        adoptable = apps.compactMap { app -> AdoptableApp? in
            guard let catalog, !managedNames.contains(app.name), managedPaths[app.path] == nil,
                  !app.fromAppStore, !(app.bundleID ?? "").hasPrefix("com.apple."),
                  let entries = catalog[app.name], !entries.isEmpty
            else { return nil }
            // Plusieurs casks pour la même app (firefox, firefox@beta…) : celui dont la version
            // correspond, sinon la variante principale (sans « @ »).
            let entry = entries.first { app.matches($0.version) }
                ?? entries.first { !$0.token.contains("@") }
                ?? entries[0]
            // Plus récente que le cask (bêta…) : la remplacer reviendrait à revenir en arrière.
            guard app.matches(entry.version) || !VersionMatch.isNewer(app.displayVersion, than: entry.version) else { return nil }
            return AdoptableApp(path: app.path, name: app.name, version: app.displayVersion,
                                cask: entry.token, caskVersion: entry.version,
                                versionMatches: app.matches(entry.version))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        hasScanned = true
    }

    /// Commande qui confie une app installée à la main à Homebrew : adoption sans
    /// téléchargement si la version correspond, sinon remplacement par la version du cask.
    func adoptCommand(_ app: AdoptableApp) -> String {
        command(["install", "--cask", app.versionMatches ? "--adopt" : "--force", app.cask])
    }

    /// Met une copie en double à la Corbeille (récupérable).
    func trashCopy(_ path: String) async {
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            message = nil
        } catch {
            message = String(localized: "Impossible de mettre à la Corbeille : \(error.localizedDescription)")
        }
        await reload()
        await scanCoherence()
    }

    /// Fait oublier une app à Homebrew sans y toucher : son dossier du Caskroom (registre de
    /// la version installée) part à la Corbeille. Pour une app que Homebrew ne doit plus gérer
    /// (bêta installée à la main, app qui se met à jour seule…). L'app dans /Applications reste.
    func forget(cask: String) async {
        guard let prefix else { return }
        let record = URL(fileURLWithPath: "\(prefix)/Caskroom/\(cask)")
        do {
            try FileManager.default.trashItem(at: record, resultingItemURL: nil)
            message = nil
        } catch {
            message = String(localized: "Impossible de retirer \(cask) du registre de Homebrew : \(error.localizedDescription)")
        }
        await reload()
        await scanCoherence()
    }

    // MARK: - Désinstallation

    /// Paquets installés qui dépendent de chaque formule (`brew uses --installed`).
    func installedDependents(of formulae: [String]) async -> [String: [String]] {
        var result: [String: [String]] = [:]
        for name in formulae {
            let output = await brew(["uses", "--installed", name]).output
            let users = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains(" ") && !$0.hasPrefix("==>") && !$0.hasSuffix(":") }
            if !users.isEmpty { result[name] = users }
        }
        return result
    }

    /// `brew uninstall` (avec `--zap` pour effacer aussi les données des apps, et
    /// `--ignore-dependencies` pour forcer), puis `brew autoremove` pour retirer les
    /// dépendances devenues inutiles.
    func uninstallCommand(_ targets: [BrewPackage], zap: Bool, ignoreDependencies: Bool) -> String {
        let formulae = targets.filter { $0.kind == .formula }.map(\.name)
        let casks = targets.filter { $0.kind == .cask }.map(\.name)
        var parts: [String] = []
        if !formulae.isEmpty {
            parts.append(command(["uninstall", "--formula"] + (ignoreDependencies ? ["--ignore-dependencies"] : []) + formulae))
        }
        if !casks.isEmpty {
            parts.append(command(["uninstall", "--cask"] + (zap ? ["--zap"] : []) + casks))
        }
        parts.append(command(["autoremove"]))
        return parts.joined(separator: " && ")
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
