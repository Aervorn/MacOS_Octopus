import Foundation

/// Lance `mo` sans terminal pour lire sa sortie JSON (`--json`).
///
/// La sortie est lue pendant l'exécution (pas seulement à la fin) : `mo analyze --json`
/// peut produire plusieurs centaines de Ko, ce qui bloquerait un tuyau lu trop tard.
final class MoleCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case exitCode(Int32)

        var errorDescription: String? {
            switch self {
            case .exitCode(let code): "Mole s'est arrêté avec le code \(code)."
            }
        }
    }

    private let process = Process()
    private let output = Pipe()

    init(executable: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["NO_COLOR": "1"]) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    /// Exécute la commande et renvoie sa sortie standard complète.
    /// Lance `CancellationError` si `cancel()` a été appelé entre-temps.
    func run() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [process, output] in
                do {
                    try process.run()
                    let data = try output.fileHandleForReading.readToEnd() ?? Data()
                    process.waitUntilExit()
                    if process.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else if process.terminationStatus != 0 {
                        continuation.resume(throwing: Failure.exitCode(process.terminationStatus))
                    } else {
                        continuation.resume(returning: data)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }

    /// Raccourci : lance, décode, renvoie.
    static func decode<T: Decodable>(_ type: T.Type, executable: String, arguments: [String]) async throws -> T {
        let data = try await MoleCapture(executable: executable, arguments: arguments).run()
        return try MoleJSON.decode(type, from: data)
    }
}
