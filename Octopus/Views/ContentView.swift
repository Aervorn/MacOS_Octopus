import SwiftUI

/// Fenêtre principale : commandes par catégorie à gauche, options et terminal à droite.
struct ContentView: View {
    private let manifest = CommandManifest.bundled
    @Environment(TerminalSession.self) private var session
    @State private var selection: String?
    /// Pour les commandes qui ont une vue native : afficher plutôt la fiche et le terminal.
    @State private var showsTerminal = false

    private var selectedCommand: CommandManifest.Command? {
        manifest.commands.first { $0.id == selection }
    }

    /// Vue native à afficher à la place de la fiche de commande, le cas échéant.
    private var nativeView: CommandManifest.NativeView? {
        guard let command = selectedCommand else { return nil }
        if command.hasTerminalMode && showsTerminal { return nil }
        return command.nativeView
    }

    /// Vue native sans mode terminal (Sécurité) qui a lancé une commande : le terminal
    /// s'affiche en bas, sous la vue, au lieu de la remplacer.
    private var showsTerminalBelowNativeView: Bool {
        nativeView != nil && selectedCommand?.hasTerminalMode == false && session.current != nil
    }

    private var terminalHeight: CGFloat {
        if nativeView == nil { return .infinity }
        return showsTerminalBelowNativeView ? 260 : 0
    }

    /// En haut, la fiche de la commande (à sa hauteur naturelle, sans défilement) ou sa vue
    /// native ; en bas, le terminal. Le terminal reste toujours monté, même masqué derrière
    /// une vue native : une commande en cours continue donc de s'exécuter et de s'afficher.
    private var detail: some View {
        VStack(spacing: 0) {
            if let nativeView, let command = selectedCommand {
                NativeCommandView(view: nativeView)
                    .id(command.id)
                    .frame(maxHeight: .infinity)
                if showsTerminalBelowNativeView {
                    Divider()
                }
            } else {
                Group {
                    if let command = selectedCommand {
                        CommandView(command: command)
                            .id(command.id)
                    } else {
                        ContentUnavailableView(
                            "Octopus",
                            systemImage: "sparkles",
                            description: Text("Une interface pour Mole : nettoyage, apps et état du Mac.")
                        )
                        .frame(height: 180)
                    }
                }
                // La pile verticale donne d'office sa hauteur idéale à la fiche,
                // puisque le terminal, lui, est extensible.
                .layoutPriority(1)

                Divider()
            }

            TerminalArea()
                .frame(height: terminalHeight == .infinity ? nil : terminalHeight)
                .frame(maxHeight: terminalHeight)
                .clipped()
                .opacity(terminalHeight == 0 ? 0 : 1)
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(manifest.categories) { category in
                    Section(category.title) {
                        let commands = manifest.commands(in: category)
                        if commands.isEmpty {
                            Label("Bientôt", systemImage: category.symbol)
                                .foregroundStyle(.tertiary)
                                .selectionDisabled()
                        }
                        ForEach(commands) { command in
                            Label(command.title, systemImage: command.symbol)
                                .tag(command.id)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { MoleStatusFooter() }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            detail
        }
        .toolbar {
            if selectedCommand?.nativeView != nil, selectedCommand?.hasTerminalMode == true {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Affichage", selection: $showsTerminal) {
                        Label("Vue", systemImage: "square.grid.2x2").tag(false)
                        Label("Terminal", systemImage: "terminal").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .help("Vue graphique ou commande dans le terminal")
                }
            }
        }
        .onChange(of: selection) { _, _ in showsTerminal = false }
        // Une commande lancée (par ex. la mise à jour depuis la barre latérale) doit être visible
        .onChange(of: session.isRunning) { _, running in
            if running && selectedCommand?.nativeView != nil && selectedCommand?.hasTerminalMode == true {
                showsTerminal = true
            }
        }
        .onAppear { if selection == nil { selection = manifest.commands.first?.id } }
    }
}

/// En bas de la barre latérale : version de Mole, installation ou mise à jour.
struct MoleStatusFooter: View {
    @Environment(MoleService.self) private var mole
    @Environment(TerminalSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            switch mole.state {
            case .checking:
                Label("Recherche de Mole…", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            case .missing:
                Label("Mole n'est pas installé", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Installer Mole") {
                    session.start(title: "Installation de Mole", commandLine: MoleService.installCommand())
                }
                .disabled(session.isRunning)
            case .installed(_, let version, let method):
                Label("Mole \(version ?? "?")", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
                    .help(method == .script ? "Installé avec le script officiel" : "Installé avec Homebrew")
                if mole.updateAvailable, let latest = mole.latestVersion,
                   let command = mole.updateCommand(arguments: ["update"]) {
                    Button("Mettre à jour vers \(latest)") {
                        session.start(title: "Mise à jour de Mole", commandLine: command)
                    }
                    .disabled(session.isRunning)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Après une installation ou une mise à jour, on relit la version.
        .onChange(of: session.isRunning) { _, running in
            if !running { Task { await mole.refresh(checkLatest: false) } }
        }
    }
}


/// Vue native d'une commande, une fois Mole trouvé.
struct NativeCommandView: View {
    let view: CommandManifest.NativeView
    @Environment(MoleService.self) private var mole

    var body: some View {
        switch view {
        // Ces vues ne dépendent pas de Mole
        case .security: SecurityView()
        case .ssh: SSHView()
        case .ports: PortsView()
        default: moleView
        }
    }

    @ViewBuilder private var moleView: some View {
        if let executable = mole.executablePath {
            switch view {
            case .security, .ssh, .ports: EmptyView()
            case .status: StatusDashboardView(executable: executable)
            case .analyze: AnalyzeView(executable: executable)
            case .history: HistoryView(executable: executable)
            }
        } else {
            ContentUnavailableView(
                "Mole introuvable",
                systemImage: "exclamationmark.triangle",
                description: Text("Installe Mole depuis le bas de la barre latérale.")
            )
        }
    }
}
