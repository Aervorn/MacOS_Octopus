import AppKit
import SwiftUI

/// Fiche d'une commande : description, options, ligne de commande générée, lancement.
struct CommandView: View {
    let command: CommandManifest.Command

    @Environment(MoleService.self) private var mole
    @Environment(TerminalSession.self) private var session
    @State private var input: CommandInput
    @State private var confirmingLiveRun = false

    init(command: CommandManifest.Command) {
        self.command = command
        _input = State(initialValue: CommandInput(defaultsFor: command))
    }

    private var arguments: [String] { input.arguments(for: command) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let positional = command.positional {
                positionalField(positional)
            }
            let options = command.options ?? []
            let toggles = options.filter { $0.type == .toggle }
            let fields = options.filter { $0.type != .toggle }
            if !toggles.isEmpty {
                // Cases à cocher réparties en colonnes selon la largeur de la fenêtre
                ColumnsLayout {
                    ForEach(toggles) { optionRow($0) }
                }
            }
            ForEach(fields) { optionRow($0) }
            commandPreview
            buttons
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Lancer « \(command.title) » pour de vrai ?",
            isPresented: $confirmingLiveRun
        ) {
            Button("Lancer", role: .destructive) { launch(arguments) }
        } message: {
            Text(input.hasDangerousOption(for: command)
                 ? "Une option dangereuse est cochée : les fichiers ne passeront pas forcément par la Corbeille."
                 : "L'aperçu (--dry-run) est désactivé : Mole va modifier ton Mac.")
        }
    }

    // MARK: - Morceaux

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: command.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title).font(.title2.bold())
                if let subtitle = command.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func positionalField(_ positional: CommandManifest.Positional) -> some View {
        HStack {
            TextField(positional.label, text: $input.positional)
                .textFieldStyle(.roundedBorder)
            if positional.type == .path {
                Button("Choisir…") { choosePath { input.positional = $0 } }
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: CommandManifest.Option) -> some View {
        switch option.type {
        case .toggle:
            Toggle(isOn: Binding(
                get: { input.toggles[option.flag] ?? false },
                set: { input.set(option.flag, $0, in: command) }
            )) {
                HStack(spacing: 6) {
                    Text(option.label)
                        .foregroundStyle(option.isDangerous ? Color.red : Color.primary)
                    Text(option.flag)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
        case .path, .number, .text:
            HStack {
                Text(option.label)
                TextField(option.flag, text: Binding(
                    get: { input.values[option.flag] ?? "" },
                    set: { input.values[option.flag] = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                if option.type == .path {
                    Button("Choisir…") { choosePath { input.values[option.flag] = $0 } }
                }
            }
        }
    }

    private var commandPreview: some View {
        let line = command.mode == .update
            ? (mole.updateCommand(arguments: arguments) ?? "mo " + Shell.join(arguments))
            : "mo " + Shell.join(arguments)
        return Text(line)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var buttons: some View {
        HStack {
            Button {
                if input.isLiveRun(for: command) || input.hasDangerousOption(for: command) {
                    confirmingLiveRun = true
                } else {
                    launch(arguments)
                }
            } label: {
                Label(input.isLiveRun(for: command) ? "Lancer" : "Lancer l'aperçu", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(input.isLiveRun(for: command) ? Color.red : Color.accentColor)
            .keyboardShortcut(.return, modifiers: .command)

            ForEach(command.actions ?? []) { action in
                Button(action.title) { launch(action.argv) }
            }
        }
        .disabled(session.isRunning || mole.executablePath == nil)
    }

    // MARK: - Actions

    private func launch(_ arguments: [String]) {
        guard let path = mole.executablePath else { return }
        let commandLine: String
        if command.mode == .update, arguments.first == "update",
           let update = mole.updateCommand(arguments: arguments) {
            commandLine = update
        } else {
            commandLine = Shell.join([path] + arguments)
        }
        session.start(title: "mo " + Shell.join(arguments), commandLine: commandLine)
    }

    private func choosePath(_ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}
