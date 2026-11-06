import Foundation

/// Lance un outil système (csrutil, spctl, softwareupdate…) et renvoie sa sortie.
///
/// Sortie standard et sortie d'erreur sont réunies : plusieurs outils écrivent leur
/// réponse sur la sortie d'erreur (« No new software available. »). La langue est forcée
/// en anglais pour que les réponses restent analysables quelle que soit celle du Mac.
enum SystemCommand {
    struct Result {
        let status: Int32
        let output: String

        var succeeded: Bool { status == 0 }
    }

    static func run(_ executable: String, _ arguments: [String] = [],
                    environment extra: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["LANG"] = "en_US.UTF-8"
                environment["LC_ALL"] = "en_US.UTF-8"
                environment.merge(extra) { $1 }
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                    process.waitUntilExit()
                    let text = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: Result(status: process.terminationStatus, output: text))
                } catch {
                    continuation.resume(returning: Result(status: -1, output: error.localizedDescription))
                }
            }
        }
    }
}
