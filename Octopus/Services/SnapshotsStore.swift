import Foundation
import Observation

/// Instantané local de Time Machine (copie de l'état du disque, gardée sur le Mac lui-même).
struct LocalSnapshot: Identifiable, Equatable {
    /// « com.apple.TimeMachine.2026-11-06-120015.local »
    let name: String
    /// « 2026-11-06-120015 » : identifiant attendu par `tmutil deletelocalsnapshots`.
    let dateStamp: String
    let date: Date?

    var id: String { name }
}

/// Liste et supprime les instantanés locaux de Time Machine.
///
/// macOS les supprime tout seul quand la place vient à manquer, mais ils peuvent occuper
/// des dizaines de Go entre-temps : c'est une partie de l'espace « purgeable ».
@MainActor
@Observable
final class SnapshotsStore {
    private(set) var snapshots: [LocalSnapshot] = []
    private(set) var isLoading = false
    private(set) var message: String?
    /// Espace libre réel et espace libre « disponible » (qui compte le purgeable).
    private(set) var freeSpace: Int64?
    private(set) var availableSpace: Int64?

    /// Espace que macOS peut libérer à la demande : instantanés, caches, fichiers iCloud téléchargés…
    var purgeable: Int64? {
        guard let freeSpace, let availableSpace, availableSpace > freeSpace else { return nil }
        return availableSpace - freeSpace
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        let result = await SystemCommand.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        snapshots = result.output.split(separator: "\n").compactMap { line in
            let name = line.trimmingCharacters(in: .whitespaces)
            guard name.hasPrefix("com.apple.TimeMachine."), name.hasSuffix(".local") else { return nil }
            let stamp = String(name.dropFirst("com.apple.TimeMachine.".count).dropLast(".local".count))
            return LocalSnapshot(name: name, dateStamp: stamp, date: Self.formatter.date(from: stamp))
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }

        let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        freeSpace = values?.volumeAvailableCapacity.map(Int64.init)
        availableSpace = values?.volumeAvailableCapacityForImportantUsage
    }

    /// Supprime des instantanés (droits administrateur, une seule autorisation pour tous).
    func delete(_ items: [LocalSnapshot]) async {
        guard !items.isEmpty else { return }
        let commands = items.map { "/usr/bin/tmutil deletelocalsnapshots \(Shell.quote($0.dateStamp))" }
        await run(commands.joined(separator: "; "),
                  success: items.count == 1 ? "Instantané supprimé." : "\(items.count) instantanés supprimés.")
    }

    func deleteAll() async {
        await run("/usr/bin/tmutil deletelocalsnapshots /", success: "Tous les instantanés locaux ont été supprimés.")
    }

    private func run(_ command: String, success: String) async {
        let before = purgeable
        do {
            _ = try await PrivilegedShell.run(command)
            await reload()
            if let before, let after = purgeable, before > after {
                message = success + " Environ \(Fmt.bytes(before - after)) libérés."
            } else {
                message = success
            }
        } catch {
            message = error.localizedDescription
            await reload()
        }
    }
}
