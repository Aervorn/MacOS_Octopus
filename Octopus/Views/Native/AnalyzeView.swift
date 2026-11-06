import AppKit
import SwiftUI

/// Explorateur du disque alimenté par `mo analyze --json`.
///
/// Un double-clic sur un dossier l'analyse à son tour ; le fil d'Ariane permet de remonter.
struct AnalyzeView: View {
    let executable: String

    /// Dossiers visités, du premier au courant. `nil` = vue globale du Mac.
    @State private var trail: [String?] = []
    @State private var result: MoleAnalysis?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var capture: MoleCapture?
    @State private var selection: MoleAnalysis.Entry.ID?

    private var currentPath: String?? { trail.last }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .onDisappear { capture?.cancel() }
    }

    // MARK: - Barre d'outils

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button("Retour", systemImage: "chevron.left") { goBack() }
                .labelStyle(.iconOnly)
                .disabled(trail.count < 2 || isLoading)

            breadcrumb
            Spacer()

            if isLoading {
                ProgressView().controlSize(.small)
                Button("Annuler") { capture?.cancel() }
            } else {
                Button("Choisir un dossier…", systemImage: "folder") { chooseFolder() }
                Button("Tout le Mac", systemImage: "desktopcomputer") { open(nil) }
                if !trail.isEmpty {
                    Button("Actualiser", systemImage: "arrow.clockwise") { load() }
                        .labelStyle(.iconOnly)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var breadcrumb: some View {
        if let path = currentPath {
            Text(path.map(displayPath) ?? "Tout le Mac")
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: - Contenu

    @ViewBuilder private var content: some View {
        if let errorMessage {
            ErrorBanner(message: errorMessage) { load() }
                .padding(14)
            Spacer()
        } else if isLoading && result == nil {
            ProgressView("Analyse en cours… Cela peut prendre un moment pour un gros dossier.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result {
            results(result)
                .opacity(isLoading ? 0.4 : 1)
        } else {
            startScreen
        }
    }

    private var startScreen: some View {
        VStack(spacing: 14) {
            Image(systemName: "chart.pie")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Où part l'espace disque ?").font(.title2.bold())
            Text("Choisis ce que Mole doit analyser. L'analyse de tout le Mac peut prendre plusieurs minutes.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Mon dossier personnel") {
                    open(FileManager.default.homeDirectoryForCurrentUser.path)
                }
                .buttonStyle(.borderedProminent)
                Button("Choisir un dossier…") { chooseFolder() }
                Button("Tout le Mac") { open(nil) }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func results(_ result: MoleAnalysis) -> some View {
        let entries = (result.entries ?? []).filter { $0.size > 0 }
        let largest = max(entries.map(\.size).max() ?? 1, 1)

        return HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                summary(result)
                Divider()
                List(selection: $selection) {
                    ForEach(entries) { entry in
                        EntryRow(entry: entry, largest: largest)
                            .tag(entry.id)
                    }
                }
                .contextMenu(forSelectionType: MoleAnalysis.Entry.ID.self) { ids in
                    if let id = ids.first, let entry = entries.first(where: { $0.id == id }) {
                        menu(for: entry)
                    }
                } primaryAction: { ids in
                    // Double-clic : on entre dans le dossier
                    if let id = ids.first, let entry = entries.first(where: { $0.id == id }),
                       entry.isDir, !entry.isSymlink {
                        open(entry.path)
                    }
                }
            }
            .frame(minWidth: 380)

            largeFiles(result.largeFiles ?? [])
                .frame(minWidth: 260, idealWidth: 320)
        }
    }

    private func summary(_ result: MoleAnalysis) -> some View {
        HStack(spacing: 20) {
            BigValue(value: Fmt.bytes(result.totalSize), caption: "au total")
            BigValue(value: Fmt.integer(result.totalFiles), caption: "fichiers")
            Spacer()
            if result.scanStatus == .partial {
                Label("Analyse partielle : certains dossiers protégés n'ont pas pu être lus.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 260, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(14)
    }

    private func largeFiles(_ files: [MoleAnalysis.LargeFile]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Gros fichiers")
                .font(.headline)
                .padding(14)
            Divider()
            List(files) { file in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(file.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.bytes(file.size)).monospacedDigit()
                    }
                    Text(displayPath((file.path as NSString).deletingLastPathComponent))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .frame(height: 36)
                .contextMenu {
                    Button("Afficher dans le Finder") { Finder.reveal(file.path) }
                    Button("Copier le chemin") { Finder.copy(file.path) }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for entry: MoleAnalysis.Entry) -> some View {
        if entry.isDir && !entry.isSymlink {
            Button("Analyser ce dossier") { open(entry.path) }
        }
        Button("Afficher dans le Finder") { Finder.reveal(entry.path) }
        Button("Copier le chemin") { Finder.copy(entry.path) }
    }

    // MARK: - Navigation

    private func open(_ path: String?) {
        trail.append(path)
        load()
    }

    private func goBack() {
        guard trail.count > 1 else { return }
        trail.removeLast()
        load()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            open(url.path)
        }
    }

    private func load() {
        guard let path = currentPath else { return }
        capture?.cancel()
        var arguments = ["analyze", "--json"]
        if let path { arguments.append(path) }
        let capture = MoleCapture(executable: executable, arguments: arguments)
        self.capture = capture
        isLoading = true
        errorMessage = nil
        selection = nil

        Task {
            do {
                let data = try await capture.run()
                let decoded = try MoleJSON.decode(MoleAnalysis.self, from: data)
                guard self.capture === capture else { return }
                result = decoded
            } catch is CancellationError {
                // Annulé (nouvelle analyse ou bouton Annuler) : on garde l'affichage précédent
            } catch {
                guard self.capture === capture else { return }
                errorMessage = "L'analyse a échoué : \(error.localizedDescription)"
            }
            if self.capture === capture {
                isLoading = false
                self.capture = nil
            }
        }
    }
}

/// Une ligne de l'explorateur : icône, nom, barre proportionnelle, taille.
private struct EntryRow: View {
    let entry: MoleAnalysis.Entry
    let largest: Int64

    private var symbol: String {
        if entry.isSymlink { return "arrow.turn.up.right" }
        return entry.isDir ? "folder.fill" : "doc"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(entry.isDir ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(entry.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
            if entry.scanStatus == .partial {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Analyse partielle : une partie du contenu est protégée")
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(2, proxy.size.width * Double(entry.size) / Double(largest)))
            }
            .frame(width: 140, height: 6)
            Text(Fmt.bytes(entry.size))
                .monospacedDigit()
                .frame(width: 80, alignment: .trailing)
        }
        // Hauteur fixe : des lignes de hauteurs différentes font trembler la liste en bas
        .frame(height: 24)
    }
}
