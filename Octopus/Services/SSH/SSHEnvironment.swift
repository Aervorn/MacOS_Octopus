import Foundation

/// Variables SSH du shell de l'utilisateur.
///
/// Une app lancée depuis le Finder ne lit pas ~/.zshrc : si l'agent SSH y est défini
/// (1Password, Secretive, gpg-agent…), elle ne le voit pas et l'authentification échoue.
/// On demande donc la valeur à un zsh interactif, une seule fois.
enum SSHEnvironment {
    @MainActor private static var cached: [String: String]?

    /// Valeurs déjà lues (vide tant que `variables()` n'a pas été appelée).
    @MainActor static var current: [String: String] { cached ?? [:] }

    @MainActor
    static func variables() async -> [String: String] {
        if let cached { return cached }
        let marker = "__OCTOPUS__"
        let result = await SystemCommand.run("/bin/zsh", ["-l", "-i", "-c", "printf '\(marker)%s' \"$SSH_AUTH_SOCK\""])
        var variables: [String: String] = [:]
        // Le profil peut afficher du texte au démarrage : on ne garde que ce qui suit le repère
        if let range = result.output.range(of: marker, options: .backwards) {
            let socket = String(result.output[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !socket.isEmpty { variables["SSH_AUTH_SOCK"] = socket }
        }
        cached = variables
        return variables
    }
}
