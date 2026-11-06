import AppKit
import SwiftUI

/// LaunchAgents et LaunchDaemons installés par des apps : ce qui démarre tout seul sur le Mac.
struct LaunchItemsView: View {
    @State private var store = LaunchItemsStore()
    @State private var scopeFilter: LaunchItem.Scope?
    @State private var problemsOnly = false
    @State private var search = ""
    @State private var selection = Set<LaunchItem.ID>()
    @State private var trashing: [LaunchItem] = []
    @State private var plist: (item: LaunchItem, text: String)?
    /// Tri choisi en cliquant sur les en-têtes (un second clic inverse l'ordre).
    @State private var sortOrder = [KeyPathComparator(\LaunchItem.label)]

    private var filtered: [LaunchItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.items.filter { item in
            (scopeFilter == nil || item.scope == scopeFilter)
                && (!problemsOnly || item.isOrphan || item.signer.isSuspicious)
                && (query.isEmpty
                    || item.label.localizedCaseInsensitiveContains(query)
                    || (item.program?.localizedCaseInsensitiveContains(query) ?? false)
                    || item.signer.title.localizedCaseInsensitiveContains(query))
        }
        .sorted(using: sortOrder)
    }

    private var selectedItems: [LaunchItem] { store.items.filter { selection.contains($0.id) } }

    private func items(_ ids: Set<LaunchItem.ID>) -> [LaunchItem] {
        store.items.filter { ids.contains($0.id) }
    }
    private var orphanCount: Int { store.items.filter(\.isOrphan).count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            table
            Divider()
            footer
        }
        .task { await store.reload() }
        .confirmationDialog(
            trashing.count == 1
                ? "Mettre « \(trashing[0].fileName) » à la Corbeille ?"
                : "Mettre \(trashing.count) éléments à la Corbeille ?",
            isPresented: Binding(get: { !trashing.isEmpty }, set: { if !$0 { trashing = [] } })
        ) {
            Button("Mettre à la Corbeille", role: .destructive) {
                let targets = trashing
                selection.removeAll()
                Task { await store.moveToTrash(targets) }
            }
        } message: {
            Text(trashing.allSatisfy(\.isOrphan)
                 ? "Leur programme n'existe plus : ce sont très probablement des restes d'apps désinstallées."
                 : "Les éléments sont arrêtés et leurs fichiers partent à la Corbeille. Une app qui en dépend pourrait ne plus fonctionner correctement, ou les réinstaller."
                   + (trashing.contains { $0.scope != .user } ? " Touch ID ou ton mot de passe te seront demandés une fois." : ""))
        }
        .sheet(isPresented: Binding(get: { plist != nil }, set: { if !$0 { plist = nil } })) {
            if let plist {
                PlistSheet(item: plist.item, text: plist.text)
            }
        }
    }

    // MARK: - Barres

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("Portée", selection: $scopeFilter) {
                Text("Tout").tag(LaunchItem.Scope?.none)
                ForEach(LaunchItem.Scope.allCases) { Text($0.title).tag(LaunchItem.Scope?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Toggle("Problèmes seulement", isOn: $problemsOnly)
                .toggleStyle(.checkbox)
                .help("Programmes introuvables (restes d'apps) et programmes non signés")
            Spacer()
            TextField("Rechercher", text: $search, prompt: Text("Nom, éditeur, programme"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
            if store.isLoading { ProgressView().controlSize(.small) }
            Button("Actualiser", systemImage: "arrow.clockwise") { Task { await store.reload() } }
                .labelStyle(.iconOnly)
                .disabled(store.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        let selected = selectedItems
        return HStack(spacing: 12) {
            if !selected.isEmpty {
                if selected.contains(where: { !$0.isDisabled }) {
                    Button("Désactiver", systemImage: "pause.circle") {
                        Task { await store.disable(selected.filter { !$0.isDisabled }) }
                    }
                }
                if selected.contains(where: \.isDisabled) {
                    Button("Activer", systemImage: "play.circle") {
                        Task { await store.enable(selected.filter(\.isDisabled)) }
                    }
                }
                if selected.count == 1 {
                    Button("Voir le plist", systemImage: "doc.text") { showPlist(selected[0]) }
                }
                Button(selected.count == 1 ? "Mettre à la Corbeille…" : "Mettre les \(selected.count) à la Corbeille…",
                       systemImage: "trash") { trashing = selected }
                if selected.count > 1 {
                    Text("\(selected.count) sélectionnés").font(.caption).foregroundStyle(.secondary)
                }
            } else if orphanCount > 0 {
                Label("\(orphanCount) élément\(orphanCount > 1 ? "s" : "") dont le programme n'existe plus", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                Button("Sélectionner") {
                    selection = Set(store.items.filter(\.isOrphan).map(\.id))
                }
                .controlSize(.small)
            } else {
                Text("Sélectionne un ou plusieurs éléments (⌘ ou ⇧ clic) pour les désactiver ou les supprimer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        // Hauteur fixe : le tableau ne change pas de taille selon le contenu de la barre
        .frame(height: 40)
    }

    // MARK: - Tableau

    private var table: some View {
        Table(filtered, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Élément", value: \.label) { item in
                ItemCell(item: item)
            }
            .width(min: 220, ideal: 320)

            TableColumn("Portée", value: \.scopeRank) { item in
                Text(item.scope.title).foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 130)

            TableColumn("Lancement", value: \.scheduleRank) { item in
                Text(item.schedule)
            }
            .width(min: 90, ideal: 150)

            TableColumn("État", value: \.stateRank) { item in
                HStack(spacing: 6) {
                    Circle().fill(stateColor(item.state)).frame(width: 8, height: 8)
                    Text(item.state.title)
                }
            }
            .width(min: 90, ideal: 140)

            TableColumn("Éditeur", value: \.signerName) { item in
                HStack(spacing: 4) {
                    if item.signer.isSuspicious {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Text(item.signer.title)
                        .foregroundStyle(item.signer.isSuspicious ? Color.orange : Color.primary)
                        .lineLimit(1)
                }
                .help(teamHelp(item.signer))
            }
            .width(min: 100, ideal: 180)

            TableColumn("Programme", value: \.programPath) { item in
                Text(item.program.map(shortPath) ?? "—")
                    .font(.callout.monospaced())
                    .foregroundStyle(item.isOrphan ? Color.orange : Color.secondary)
                    .strikethrough(item.isOrphan)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.program ?? "")
            }
            .width(min: 160, ideal: 300)
        }
        .contextMenu(forSelectionType: LaunchItem.ID.self) { ids in
            let targets = items(ids)
            if targets.count == 1, let item = targets.first {
                if item.isDisabled {
                    Button("Activer") { Task { await store.enable([item]) } }
                } else {
                    Button("Désactiver") { Task { await store.disable([item]) } }
                }
                Button("Voir le plist") { showPlist(item) }
                Button("Afficher le plist dans le Finder") { Finder.reveal(item.path) }
                if let program = item.program, item.programExists == true {
                    Button("Afficher le programme dans le Finder") { Finder.reveal(program) }
                }
                if let app = item.owningAppURL {
                    Button("Afficher l'app dans le Finder") { Finder.reveal(app.path) }
                }
                Divider()
                Button("Mettre à la Corbeille…", role: .destructive) { trashing = [item] }
            } else if targets.count > 1 {
                Button("Désactiver les \(targets.count)") {
                    Task { await store.disable(targets.filter { !$0.isDisabled }) }
                }
                .disabled(targets.allSatisfy(\.isDisabled))
                Button("Activer les \(targets.count)") {
                    Task { await store.enable(targets.filter(\.isDisabled)) }
                }
                .disabled(!targets.contains(where: \.isDisabled))
                Divider()
                Button("Mettre les \(targets.count) à la Corbeille…", role: .destructive) { trashing = targets }
            }
        } primaryAction: { ids in
            if ids.count == 1, let item = items(ids).first { showPlist(item) }
        }
        .overlay {
            if !store.isLoading && store.items.isEmpty {
                ContentUnavailableView("Aucun élément de démarrage", systemImage: "power",
                                       description: Text("Aucune app n'a installé de LaunchAgent ou de LaunchDaemon."))
            } else if !store.items.isEmpty && filtered.isEmpty {
                ContentUnavailableView("Aucun résultat", systemImage: "magnifyingglass")
            }
        }
    }

    // MARK: - Outils

    private func stateColor(_ state: LaunchItem.State) -> Color {
        switch state {
        case .running: .green
        case .loaded(let code?) where code != 0: .orange
        case .loaded: .blue
        case .notLoaded, .unknown: .gray
        case .disabled: .secondary
        }
    }

    private func teamHelp(_ signer: LaunchItem.Signer) -> String {
        switch signer {
        case .developer(let name, let team?): "\(name) — équipe \(team)"
        case .unsigned: "Le programme n'est pas signé : son origine ne peut pas être vérifiée."
        case .adHoc: "Signature locale, sans identité de développeur vérifiée."
        default: signer.title
        }
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.replacingOccurrences(of: home, with: "~")
    }

    private func showPlist(_ item: LaunchItem) {
        Task { plist = (item, await LaunchItemsStore.plistText(item)) }
    }
}

/// Icône de l'app propriétaire (ou générique), label et nom de fichier.
private struct ItemCell: View {
    let item: LaunchItem

    private var icon: NSImage? {
        item.owningAppURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: item.scope == .system ? "gearshape.2" : "gearshape")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.label).lineLimit(1).truncationMode(.middle)
                    if item.isOrphan {
                        Badge(text: "Programme introuvable", color: .orange)
                    }
                }
                // Toujours une deuxième ligne : toutes les lignes ont la même hauteur
                Text(item.owningAppURL.map { $0.deletingPathExtension().lastPathComponent } ?? item.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .opacity(item.isDisabled ? 0.55 : 1)
        // Hauteur fixe : des lignes de hauteurs différentes font trembler le tableau
        // en bas de liste (macOS recalcule sans cesse la hauteur totale).
        .frame(height: 32)
    }
}

/// Contenu du .plist, en lecture seule.
private struct PlistSheet: View {
    let item: LaunchItem
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text(item.label).font(.title3.bold())
                    Text(item.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Afficher dans le Finder") { Finder.reveal(item.path) }
            }
            ScrollView {
                Text(text)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Spacer()
                Button("Fermer") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
    }
}
