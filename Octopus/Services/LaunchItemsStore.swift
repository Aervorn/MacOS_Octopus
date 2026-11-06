import AppKit
import Darwin
import Foundation
import Observation

/// Un LaunchAgent ou LaunchDaemon (fichier .plist lu par launchd).
struct LaunchItem: Identifiable, Equatable {
    enum Scope: String, CaseIterable, Identifiable {
        /// ~/Library/LaunchAgents : pour toi seulement.
        case user
        /// /Library/LaunchAgents : pour chaque utilisateur, à l'ouverture de session.
        case allUsers
        /// /Library/LaunchDaemons : pour tout le Mac, en root, dès le démarrage.
        case system

        var id: Self { self }

        var title: String {
            switch self {
            case .user: String(localized: "Mon compte")
            case .allUsers: String(localized: "Tous les utilisateurs")
            case .system: String(localized: "Système (root)")
            }
        }

        var directory: URL {
            switch self {
            case .user: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
            case .allUsers: URL(fileURLWithPath: "/Library/LaunchAgents")
            case .system: URL(fileURLWithPath: "/Library/LaunchDaemons")
            }
        }

        /// Domaine launchctl : la session de l'utilisateur, ou le système.
        var domain: String { self == .system ? "system" : "gui/\(getuid())" }
        /// Les éléments hors de ton dossier demandent les droits administrateur pour être supprimés.
        var needsAdmin: Bool { self != .user }
    }

    enum State: Equatable {
        case running(pid: Int)
        /// Chargé par launchd mais pas en cours (lancé à la demande, ou terminé).
        case loaded(lastExit: Int?)
        case notLoaded
        case disabled
        case unknown

        var title: String {
            switch self {
            case .running(let pid): String(localized: "En cours (PID \(pid))")
            case .loaded(let code?) where code != 0: String(localized: "Arrêté (code \(code))")
            case .loaded: String(localized: "Prêt")
            case .notLoaded: String(localized: "Non chargé")
            case .disabled: String(localized: "Désactivé")
            case .unknown: String(localized: "Inconnu")
            }
        }
    }

    enum Signer: Equatable {
        case apple
        case developer(name: String, team: String?)
        case adHoc
        case unsigned
        case unknown

        var title: String {
            switch self {
            case .apple: "Apple"
            case .developer(let name, _): name
            case .adHoc: String(localized: "Signature locale")
            case .unsigned: String(localized: "Non signé")
            case .unknown: "—"
            }
        }

        var isSuspicious: Bool { self == .unsigned || self == .adHoc }
    }

    let path: String
    let label: String
    let scope: Scope
    /// Exécutable lancé (Program, ou premier élément de ProgramArguments).
    let program: String?
    let arguments: [String]
    /// `nil` : chemin relatif à une app (BundleProgram), on ne peut pas vérifier.
    let programExists: Bool?
    let runAtLoad: Bool
    let keepAlive: Bool
    let startInterval: Int?
    let hasCalendarInterval: Bool
    let watchesPaths: Bool
    /// Apps déclarées dans AssociatedBundleIdentifiers.
    let associatedBundleIDs: [String]
    let modified: Date?

    var state: State = .unknown
    var signer: Signer = .unknown

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }

    /// Programme introuvable : très probablement le reste d'une app désinstallée.
    var isOrphan: Bool { programExists == false }

    var isDisabled: Bool { state == .disabled }

    // MARK: Clés de tri (en-têtes du tableau)

    var scopeRank: Int { LaunchItem.Scope.allCases.firstIndex(of: scope) ?? 0 }
    var stateRank: Int {
        switch state {
        case .running: 0
        case .loaded: 1
        case .notLoaded: 2
        case .disabled: 3
        case .unknown: 4
        }
    }
    var signerName: String { signer.title }
    var programPath: String { program ?? "" }
    /// Ordre logique : permanent, intervalle (plus court d'abord), planifié, au démarrage, à la demande.
    var scheduleRank: Int {
        if keepAlive { return 0 }
        if let interval = startInterval { return 1 + min(interval, 1_000_000) }
        if hasCalendarInterval { return 2_000_000 }
        if watchesPaths { return 3_000_000 }
        if runAtLoad { return 4_000_000 }
        return 5_000_000
    }

    var schedule: String {
        if keepAlive { return String(localized: "Permanent") }
        if let interval = startInterval {
            return interval >= 3600 && interval % 3600 == 0 ? String(localized: "Toutes les \(interval / 3600) h")
                : interval >= 60 ? String(localized: "Toutes les \(interval / 60) min") : String(localized: "Toutes les \(interval) s")
        }
        if hasCalendarInterval { return String(localized: "Planifié") }
        if watchesPaths { return String(localized: "Sur modification") }
        if runAtLoad { return scope == .system ? String(localized: "Au démarrage") : String(localized: "À l'ouverture de session") }
        return String(localized: "À la demande")
    }

    /// App à laquelle l'élément appartient, déduite des identifiants déclarés ou du chemin du programme.
    var owningAppURL: URL? {
        for bundleID in associatedBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        }
        if let program, let range = program.range(of: ".app/") {
            return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
        }
        return nil
    }
}

/// Lit les LaunchAgents et LaunchDaemons installés par des apps (pas ceux d'Apple, dans /System).
@MainActor
@Observable
final class LaunchItemsStore {
    private(set) var items: [LaunchItem] = []
    private(set) var isLoading = false
    private(set) var message: String?

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        var found: [LaunchItem] = []
        for scope in LaunchItem.Scope.allCases {
            found += Self.readItems(in: scope)
        }

        // États : liste de la session (sans droits), désactivations des deux domaines
        let userList = Self.parseLaunchctlList(await SystemCommand.run("/bin/launchctl", ["list"]).output)
        let userDisabled = Self.parseDisabled(await SystemCommand.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"]).output)
        let systemDisabled = Self.parseDisabled(await SystemCommand.run("/bin/launchctl", ["print-disabled", "system"]).output)

        for index in found.indices {
            let item = found[index]
            if item.scope == .system {
                if systemDisabled.contains(item.label) {
                    found[index].state = .disabled
                } else {
                    found[index].state = await Self.systemState(item.label)
                }
            } else if userDisabled.contains(item.label) {
                found[index].state = .disabled
            } else if let entry = userList[item.label] {
                found[index].state = entry.pid.map { LaunchItem.State.running(pid: $0) } ?? .loaded(lastExit: entry.status)
            } else {
                found[index].state = .notLoaded
            }
        }
        items = found.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }

        // Signatures ensuite (codesign est lent) : la liste s'affiche sans attendre.
        // Toutes calculées en parallèle puis appliquées en une seule fois, pour que le
        // tableau ne se redessine pas ligne par ligne (il « tremblait » pendant le défilement).
        let programs = Set(items.filter { $0.programExists == true }.compactMap(\.program))
        let signers = await withTaskGroup(of: (String, LaunchItem.Signer).self) { group in
            for program in programs {
                group.addTask { (program, await Self.signer(of: program)) }
            }
            var result: [String: LaunchItem.Signer] = [:]
            for await (program, signer) in group { result[program] = signer }
            return result
        }
        var signed = items
        for index in signed.indices {
            if let program = signed[index].program, let signer = signers[program] {
                signed[index].signer = signer
            }
        }
        items = signed
    }

    // MARK: - Actions

    /// Arrête les éléments et empêche launchd de les relancer (réversible avec `enable`).
    func disable(_ items: [LaunchItem]) async {
        await perform(items, success: .disabled) { item in
            [
                "/bin/launchctl bootout \(item.scope.domain) \(Shell.quote(item.path)) 2>/dev/null",
                "/bin/launchctl disable \(item.scope.domain)/\(Shell.quote(item.label))",
            ]
        }
    }

    func enable(_ items: [LaunchItem]) async {
        await perform(items, success: .enabled) { item in
            [
                "/bin/launchctl enable \(item.scope.domain)/\(Shell.quote(item.label))",
                "/bin/launchctl bootstrap \(item.scope.domain) \(Shell.quote(item.path)) 2>/dev/null",
            ]
        }
    }

    /// Arrête les éléments et met leurs fichiers .plist à la Corbeille (récupérables).
    func moveToTrash(_ items: [LaunchItem]) async {
        guard !items.isEmpty else { return }
        var failures: [String] = []
        // Mes éléments : Corbeille du Finder, sans droits
        for item in items where item.scope == .user {
            _ = await SystemCommand.run("/bin/launchctl", ["bootout", item.scope.domain, item.path])
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            } catch {
                failures.append(item.fileName)
            }
        }
        // Les autres : une seule commande administrateur pour tous (un seul Touch ID)
        let others = items.filter { $0.scope != .user }
        if !others.isEmpty {
            let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path
            let commands = others.flatMap { item in
                [
                    "/bin/launchctl bootout \(item.scope.domain) \(Shell.quote(item.path)) 2>/dev/null",
                    "/bin/mv \(Shell.quote(item.path)) \(Shell.quote(trash + "/" + item.fileName))",
                ]
            }
            do {
                _ = try await PrivilegedShell.run(commands.joined(separator: "; ") + "; true")
            } catch {
                failures += others.map(\.fileName)
            }
        }
        message = failures.isEmpty
            ? (items.count == 1 ? String(localized: "« \(items[0].fileName) » est dans la Corbeille.") : String(localized: "\(items.count) éléments sont dans la Corbeille."))
            : String(localized: "Échec pour : \(failures.joined(separator: ", "))")
        await reload()
    }

    /// Lance les commandes de chaque élément : sans droits pour la session, avec une seule
    /// autorisation administrateur pour tous les éléments système.
    private enum Outcome { case disabled, enabled }

    private func perform(_ items: [LaunchItem], success: Outcome, commands: (LaunchItem) -> [String]) async {
        guard !items.isEmpty else { return }
        var errors: [String] = []
        let session = items.filter { $0.scope != .system }
        let system = items.filter { $0.scope == .system }

        if !session.isEmpty {
            let line = session.flatMap(commands).joined(separator: "; ") + "; true"
            let result = await SystemCommand.run("/bin/sh", ["-c", line])
            if !result.succeeded { errors.append(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if !system.isEmpty {
            do {
                _ = try await PrivilegedShell.run(system.flatMap(commands).joined(separator: "; ") + "; true")
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if let error = errors.first {
            message = error
        } else {
            switch (success, items.count == 1) {
            case (.disabled, true): message = String(localized: "« \(items[0].label) » est désactivé.")
            case (.disabled, false): message = String(localized: "\(items.count) éléments ont été désactivés.")
            case (.enabled, true): message = String(localized: "« \(items[0].label) » est réactivé.")
            case (.enabled, false): message = String(localized: "\(items.count) éléments ont été réactivés.")
            }
        }
        await reload()
    }

    /// Contenu du .plist en XML lisible.
    static func plistText(_ item: LaunchItem) async -> String {
        let result = await SystemCommand.run("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", item.path])
        return result.succeeded ? result.output : (try? String(contentsOfFile: item.path, encoding: .utf8)) ?? result.output
    }

    // MARK: - Lecture

    private static func readItems(in scope: LaunchItem.Scope) -> [LaunchItem] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: scope.directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".plist") }.compactMap { name in
            let url = scope.directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return nil }

            let label = plist["Label"] as? String ?? (name as NSString).deletingPathExtension
            let arguments = plist["ProgramArguments"] as? [String] ?? []
            let program = plist["Program"] as? String ?? arguments.first
            let bundleProgram = plist["BundleProgram"] as? String

            var exists: Bool?
            if let program, program.hasPrefix("/") {
                exists = fm.fileExists(atPath: program)
            } else if bundleProgram != nil {
                exists = nil
            }

            // KeepAlive peut être un booléen ou un dictionnaire de conditions
            let keepAlive: Bool = {
                if let value = plist["KeepAlive"] as? Bool { return value }
                return plist["KeepAlive"] is [String: Any]
            }()

            var associated = plist["AssociatedBundleIdentifiers"] as? [String] ?? []
            if let single = plist["AssociatedBundleIdentifiers"] as? String { associated = [single] }

            return LaunchItem(
                path: url.path,
                label: label,
                scope: scope,
                program: program ?? bundleProgram,
                arguments: Array(arguments.dropFirst()),
                programExists: exists,
                runAtLoad: plist["RunAtLoad"] as? Bool ?? false,
                keepAlive: keepAlive,
                startInterval: plist["StartInterval"] as? Int,
                hasCalendarInterval: plist["StartCalendarInterval"] != nil,
                watchesPaths: plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil,
                associatedBundleIDs: associated,
                modified: (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            )
        }
    }

    /// `launchctl list` : « PID  Statut  Label », PID « - » si l'élément ne tourne pas.
    static func parseLaunchctlList(_ output: String) -> [String: (pid: Int?, status: Int?)] {
        var entries: [String: (pid: Int?, status: Int?)] = [:]
        for line in output.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 3 else { continue }
            entries[String(fields[2])] = (Int(fields[0]), Int(fields[1]))
        }
        return entries
    }

    /// `launchctl print-disabled` : lignes « "label" => disabled » (ou « => true » sur les anciens macOS).
    static func parseDisabled(_ output: String) -> Set<String> {
        var disabled = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value == "disabled" || value == "true" else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            disabled.insert(label)
        }
        return disabled
    }

    /// État d'un démon système, lisible sans droits avec `launchctl print`.
    private static func systemState(_ label: String) async -> LaunchItem.State {
        let result = await SystemCommand.run("/bin/launchctl", ["print", "system/\(label)"])
        guard result.succeeded else {
            return result.output.contains("Could not find service") ? .notLoaded : .unknown
        }
        var pid: Int?
        var lastExit: Int?
        for line in result.output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = ") { pid = Int(trimmed.dropFirst(6)) }
            if trimmed.hasPrefix("last exit code = ") {
                lastExit = Int(trimmed.dropFirst(17).prefix { $0.isNumber || $0 == "-" })
            }
        }
        return pid.map { LaunchItem.State.running(pid: $0) } ?? .loaded(lastExit: lastExit)
    }

    /// Signataire du programme, d'après `codesign -dv`.
    private static func signer(of program: String) async -> LaunchItem.Signer {
        let result = await SystemCommand.run("/usr/bin/codesign", ["-dv", "--verbose=2", program])
        let out = result.output
        if out.contains("not signed at all") { return .unsigned }
        let authorities = out.split(separator: "\n")
            .filter { $0.hasPrefix("Authority=") }
            .map { String($0.dropFirst("Authority=".count)) }
        if let first = authorities.first {
            if first == "Software Signing" || first.hasPrefix("Apple ") { return .apple }
            var name = first
            for prefix in ["Developer ID Application: ", "Apple Development: ", "Mac Developer: "] where name.hasPrefix(prefix) {
                name = String(name.dropFirst(prefix.count))
            }
            let team = out.split(separator: "\n").first { $0.hasPrefix("TeamIdentifier=") }
                .map { String($0.dropFirst("TeamIdentifier=".count)) }
            return .developer(name: name, team: team)
        }
        if out.contains("Signature=adhoc") { return .adHoc }
        return .unknown
    }
}
