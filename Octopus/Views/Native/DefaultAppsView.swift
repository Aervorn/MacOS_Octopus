import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Apps par défaut : quelle app ouvre quel type de fichier (et les liens web, les e-mails).
struct DefaultAppsView: View {
    @State private var store = DefaultAppsStore()
    @State private var selection = Set<OpenWithEntry.ID>()
    @State private var search = ""
    @State private var newExtension = ""
    @State private var extensionError = false

    private var filtered: [OpenWithEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.title.localizedCaseInsensitiveContains(query)
                || entry.extensions.contains { $0.localizedCaseInsensitiveContains(query) }
                || (entry.defaultApp?.lastPathComponent.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedEntries: [OpenWithEntry] { store.entries.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            List(selection: $selection) {
                ForEach(DefaultAppsStore.familyOrder, id: \.self) { family in
                    let rows = filtered.filter { $0.family == family }
                    if !rows.isEmpty {
                        Section(family) {
                            ForEach(rows) { entry in
                                EntryRow(entry: entry, store: store)
                                    .tag(entry.id)
                                    .contextMenu {
                                        if entry.family == "Ajoutés" {
                                            Button("Retirer de la liste") { store.removeCustom(entry) }
                                        }
                                    }
                            }
                        }
                    }
                }
            }
            .overlay {
                if !store.entries.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            Divider()
            footer
        }
        .task { store.reload() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Rechercher", text: $search, prompt: Text("Type, extension ou app"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            Spacer()
            Text("Autre extension :").foregroundStyle(.secondary)
            TextField("", text: $newExtension, prompt: Text(".toml"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit(addExtension)
                .onChange(of: newExtension) { _, _ in extensionError = false }
            Button("Ajouter", action: addExtension)
                .disabled(newExtension.trimmingCharacters(in: .whitespaces).isEmpty)
            if extensionError {
                Text("Extension inconnue").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if selection.count > 1 {
                Text("\(selection.count) types sélectionnés")
                    .foregroundStyle(.secondary)
                AppMenu(title: "Tout ouvrir avec…", candidates: unionCandidates) { app in
                    Task { await store.setDefault(app, for: selectedEntries) }
                }
                .fixedSize()
            } else {
                Text("⌘-clic ou ⇧-clic pour changer plusieurs types d'un coup (par exemple tout le code vers ton éditeur).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    /// Apps capables d'ouvrir au moins un des types sélectionnés, les plus polyvalentes d'abord.
    private var unionCandidates: [URL] {
        var counts: [URL: Int] = [:]
        for entry in selectedEntries {
            for app in entry.candidates { counts[app, default: 0] += 1 }
        }
        return counts.keys.sorted { lhs, rhs in
            if counts[lhs] != counts[rhs] { return counts[lhs]! > counts[rhs]! }
            return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }
    }

    private func addExtension() {
        if store.addExtension(newExtension) {
            newExtension = ""
        } else {
            extensionError = true
        }
    }
}

/// Une ligne : icône du type, nom, extensions, app actuelle et menu pour en changer.
private struct EntryRow: View {
    let entry: OpenWithEntry
    let store: DefaultAppsStore

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: entry.icon)
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).lineLimit(1)
                Text(entry.extensionsText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            AppMenu(title: entry.defaultApp.map(appName) ?? "Aucune app",
                    icon: entry.defaultApp,
                    candidates: entry.candidates) { app in
                Task { await store.setDefault(app, for: [entry]) }
            }
            .fixedSize()
        }
        .frame(height: 34)
    }

    private func appName(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }
}

/// Menu des apps proposées, avec « Autre app… » pour en choisir une absente de la liste.
private struct AppMenu: View {
    let title: String
    var icon: URL? = nil
    let candidates: [URL]
    let onChoose: (URL) -> Void

    var body: some View {
        Menu {
            ForEach(candidates, id: \.self) { app in
                Button {
                    onChoose(app)
                } label: {
                    Label {
                        Text(app.deletingPathExtension().lastPathComponent)
                    } icon: {
                        Image(nsImage: smallIcon(app))
                    }
                }
            }
            if !candidates.isEmpty { Divider() }
            Button("Autre app…") { chooseApp() }
        } label: {
            HStack(spacing: 6) {
                if let icon {
                    Image(nsImage: smallIcon(icon))
                }
                Text(title)
            }
        }
    }

    private func smallIcon(_ app: URL) -> NSImage {
        // Copie : l'icône renvoyée est partagée, la redimensionner l'altérerait ailleurs
        let image = (NSWorkspace.shared.icon(forFile: app.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            onChoose(url)
        }
    }
}
