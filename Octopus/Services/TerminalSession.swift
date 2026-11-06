import Foundation
import Observation

/// La commande affichée dans le terminal intégré.
///
/// Chaque lancement reçoit un nouvel identifiant : la vue du terminal est recréée,
/// ce qui repart d'un écran propre et d'un nouveau processus.
@MainActor
@Observable
final class TerminalSession {
    struct Run: Identifiable, Equatable {
        let id = UUID()
        /// Titre affiché au-dessus du terminal, ex. « mo clean --dry-run ».
        let title: String
        /// Ligne de commande exécutée par `zsh -l -c`.
        let commandLine: String
    }

    private(set) var current: Run?
    private(set) var isRunning = false
    private(set) var exitCode: Int32?

    func start(title: String, commandLine: String) {
        guard !isRunning else { return }
        exitCode = nil
        isRunning = true
        current = Run(title: title, commandLine: commandLine)
    }

    func didTerminate(_ run: Run.ID, exitCode: Int32?) {
        guard run == current?.id else { return }
        isRunning = false
        self.exitCode = exitCode
    }

    func clear() {
        guard !isRunning else { return }
        current = nil
        exitCode = nil
    }
}
