import Foundation

/// Exécute une commande shell avec les droits administrateur, sans terminal.
///
/// Deux chemins :
/// 1. Si Touch ID est activé pour sudo (pam_tid, par ex. via `mo touchid enable`), on passe par
///    `sudo` : macOS affiche alors la demande Touch ID. L'autorisation de sudo reste valable
///    quelques minutes pour les commandes suivantes lancées par Octopus.
/// 2. Sinon, ou si Touch ID est refusé, AppleScript (« do shell script … with administrator
///    privileges ») : fenêtre d'autorisation de macOS, avec le mot de passe.
@MainActor
enum PrivilegedShell {
    enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: "Autorisation annulée."
            case .failed(let message): message
            }
        }
    }

    static func run(_ command: String) async throws -> String {
        if touchIDEnabledForSudo {
            let result = await SystemCommand.run("/usr/bin/sudo", ["/bin/sh", "-c", command])
            if result.succeeded { return result.output }
            // Erreur de sudo lui-même (Touch ID refusé, mot de passe requis sans terminal…) :
            // on se rabat sur la fenêtre d'autorisation de macOS. Sinon, c'est la commande qui a échoué.
            if !isSudoAuthenticationError(result.output) {
                throw Failure.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return try appleScript(command)
    }

    /// pam_tid est déclaré pour sudo (macOS 14+ : /etc/pam.d/sudo_local ; avant : /etc/pam.d/sudo).
    static var touchIDEnabledForSudo: Bool {
        ["/etc/pam.d/sudo_local", "/etc/pam.d/sudo"].contains { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("#") && trimmed.contains("pam_tid.so")
            }
        }
    }

    private static func isSudoAuthenticationError(_ output: String) -> Bool {
        let markers = ["sudo: a terminal is required", "sudo: a password is required",
                       "sudo: no tty present", "incorrect password attempt", "Sorry, try again",
                       "sudo: unable to", "sudo: Authentication failed"]
        return markers.contains { output.contains($0) }
    }

    private static func appleScript(_ command: String) throws -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges without altering line endings"
        guard let script = NSAppleScript(source: source) else {
            throw Failure.failed("Script invalide.")
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // -128 : l'utilisateur a cliqué sur Annuler
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw Failure.cancelled }
            throw Failure.failed(error[NSAppleScript.errorMessage] as? String ?? "Erreur inconnue.")
        }
        return result.stringValue ?? ""
    }
}
