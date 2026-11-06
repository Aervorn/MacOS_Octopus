import AppKit
import SwiftTerm
import SwiftUI

/// Terminal intégré : un vrai pseudo-terminal (PTY) fourni par SwiftTerm.
///
/// Les TUI de Mole (`mo status`, `mo analyze`, sélecteurs au clavier), `sudo` et Touch ID
/// y fonctionnent comme dans Terminal.app. La commande passe par `zsh -l -c` pour
/// retrouver le PATH de l'utilisateur (Homebrew, ~/.local/bin).
struct TerminalPane: NSViewRepresentable {
    let run: TerminalSession.Run
    let onTerminate: (TerminalSession.Run.ID, Int32?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(runID: run.id, onTerminate: onTerminate)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = context.coordinator
        view.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", run.commandLine],
            environment: Self.environment()
        )
        // Le clavier va directement au terminal : flèches, Entrée, Ctrl-C…
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    /// Environnement de l'app, avec un type de terminal qui gère les couleurs.
    private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"] ?? "fr_FR.UTF-8"
        return env.map { "\($0.key)=\($0.value)" }
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let runID: TerminalSession.Run.ID
        let onTerminate: (TerminalSession.Run.ID, Int32?) -> Void

        init(runID: TerminalSession.Run.ID, onTerminate: @escaping (TerminalSession.Run.ID, Int32?) -> Void) {
            self.runID = runID
            self.onTerminate = onTerminate
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let runID = runID
            let onTerminate = onTerminate
            DispatchQueue.main.async { onTerminate(runID, exitCode) }
        }
    }
}

/// Le terminal avec sa barre de titre : commande lancée, état, bouton pour effacer.
struct TerminalArea: View {
    @Environment(TerminalSession.self) private var session

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text(session.current?.title ?? "Terminal")
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                status
                Button("Effacer", systemImage: "xmark.circle") { session.clear() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(session.isRunning || session.current == nil)
                    .help("Effacer le terminal")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            if let run = session.current {
                TerminalPane(run: run) { id, code in
                    session.didTerminate(id, exitCode: code)
                }
                .id(run.id)
            } else {
                ContentUnavailableView(
                    "Aucune commande lancée",
                    systemImage: "terminal",
                    description: Text("Choisis une commande à gauche, règle ses options, puis lance-la.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private var status: some View {
        if session.isRunning {
            ProgressView().controlSize(.small)
            Text("En cours").font(.caption).foregroundStyle(.secondary)
        } else if let code = session.exitCode {
            Label(code == 0 ? "Terminé" : "Code \(code)",
                  systemImage: code == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(code == 0 ? Color.green : Color.orange)
        }
    }
}
