import Foundation
import Observation

/// Mesures en direct de `mo status --watch` (un objet JSON par ligne).
///
/// Le processus tourne tant que le tableau de bord est affiché, et s'arrête avec lui.
@MainActor
@Observable
final class StatusStore {
    struct Sample: Identifiable {
        let id = UUID()
        let date: Date
        let cpu: Double
        let memory: Double
    }

    private(set) var latest: MoleStatus?
    /// Historique récent pour les graphiques (3 minutes à une mesure toutes les 2 s).
    private(set) var samples: [Sample] = []
    private(set) var errorMessage: String?

    static let interval = 2
    static let maxSamples = 90

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(executable: String) {
        guard process == nil else { return }
        errorMessage = nil

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["status", "--watch", "--interval", "\(Self.interval)s"]
        process.environment = ProcessInfo.processInfo.environment.merging(["NO_COLOR": "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
        } catch {
            errorMessage = String(localized: "Impossible de lancer mo status : \(error.localizedDescription)")
            return
        }
        self.process = process

        let handle = pipe.fileHandleForReading
        task = Task { [weak self] in
            do {
                for try await status in MoleJSON.statusStream(from: handle) {
                    self?.receive(status)
                }
            } catch {
                // Flux interrompu : traité ci-dessous comme un arrêt.
            }
            self?.streamEnded()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
    }

    private func receive(_ status: MoleStatus) {
        latest = status
        errorMessage = nil
        let sample = Sample(
            date: status.collectedDate ?? .now,
            cpu: status.cpu?.usage ?? 0,
            memory: status.memory?.usedPercent ?? 0
        )
        samples.append(sample)
        if samples.count > Self.maxSamples {
            samples.removeFirst(samples.count - Self.maxSamples)
        }
    }

    /// Fin du flux sans qu'on l'ait demandée : mo s'est arrêté ou a planté.
    private func streamEnded() {
        guard process != nil else { return }
        process = nil
        task = nil
        errorMessage = String(localized: "mo status s'est arrêté. Relance l'affichage pour réessayer.")
    }
}
