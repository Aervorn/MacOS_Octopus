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
        /// Outil (identifiant de la barre latérale) qui a lancé la commande.
        let context: String?
    }

    /// Outil actuellement affiché, tenu à jour par la fenêtre principale.
    /// Une commande n'est visible que dans l'outil qui l'a lancée.
    var context: String?

    private(set) var current: Run?
    private(set) var isRunning = false
    private(set) var exitCode: Int32?

    func start(title: String, commandLine: String) {
        guard !isRunning else { return }
        exitCode = nil
        isRunning = true
        current = Run(title: title, commandLine: commandLine, context: context)
    }

    func didTerminate(_ run: Run.ID, exitCode: Int32?) {
        guard run == current?.id else { return }
        isRunning = false
        self.exitCode = exitCode
    }

    /// Commande à afficher dans l'outil courant : celle d'un autre outil n'est pas héritée.
    var visible: Run? {
        guard let current, current.context == context else { return nil }
        return current
    }

    /// Changement d'outil : on oublie la commande terminée de l'outil précédent.
    /// Une commande encore en cours continue, masquée, et réapparaît dans son outil.
    func switchContext(to newContext: String?) {
        context = newContext
        if !isRunning, current?.context != newContext { clear() }
    }

    func clear() {
        guard !isRunning else { return }
        current = nil
        exitCode = nil
    }
}
