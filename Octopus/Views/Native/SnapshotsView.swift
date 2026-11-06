import SwiftUI

/// Instantanés locaux de Time Machine : les voir et récupérer leur place.
struct SnapshotsView: View {
    @State private var store = SnapshotsStore()
    @State private var selection = Set<LocalSnapshot.ID>()
    @State private var confirming: [LocalSnapshot] = []
    @State private var confirmingAll = false

    var body: some View {
        VStack(spacing: 0) {
            summary
            Divider()
            Table(store.snapshots, selection: $selection) {
                TableColumn("Date") { snapshot in
                    Text(snapshot.date.map { $0.formatted(date: .complete, time: .shortened) } ?? snapshot.dateStamp)
                        .frame(height: 22)
                }
                .width(min: 200, ideal: 300)
                TableColumn("Ancienneté") { snapshot in
                    Text(snapshot.date.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 100, ideal: 140)
                TableColumn("Nom") { snapshot in
                    Text(snapshot.name).font(.callout.monospaced()).foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
            .contextMenu(forSelectionType: LocalSnapshot.ID.self) { ids in
                let targets = store.snapshots.filter { ids.contains($0.id) }
                if !targets.isEmpty {
                    Button(targets.count == 1 ? "Supprimer…" : "Supprimer les \(targets.count)…", role: .destructive) {
                        confirming = targets
                    }
                }
            }
            .overlay {
                if store.snapshots.isEmpty && !store.isLoading {
                    ContentUnavailableView("Aucun instantané local", systemImage: "clock.arrow.circlepath",
                                           description: Text("Time Machine n'en garde aucun sur ce Mac en ce moment."))
                }
            }
            Divider()
            footer
        }
        .task { await store.reload() }
        .confirmationDialog(
            confirming.count == 1 ? "Supprimer cet instantané ?" : "Supprimer \(confirming.count) instantanés ?",
            isPresented: Binding(get: { !confirming.isEmpty }, set: { if !$0 { confirming = [] } })
        ) {
            Button("Supprimer", role: .destructive) {
                let targets = confirming
                selection.removeAll()
                Task { await store.delete(targets) }
            }
        } message: {
            Text("Tes sauvegardes sur le disque Time Machine ne sont pas touchées. Seules les copies gardées sur ce Mac sont supprimées.")
        }
        .confirmationDialog("Supprimer tous les instantanés locaux ?", isPresented: $confirmingAll) {
            Button("Tout supprimer", role: .destructive) {
                selection.removeAll()
                Task { await store.deleteAll() }
            }
        } message: {
            Text("Tes sauvegardes sur le disque Time Machine ne sont pas touchées. Tu perds seulement la possibilité de restaurer ces états-là sans le disque de sauvegarde.")
        }
    }

    private var summary: some View {
        HStack(spacing: 24) {
            BigValue(value: "\(store.snapshots.count)", caption: "instantané\(store.snapshots.count > 1 ? "s" : "") local\(store.snapshots.count > 1 ? "aux" : "")")
            BigValue(value: Fmt.bytes(store.freeSpace), caption: "libres")
            if let purgeable = store.purgeable {
                BigValue(value: Fmt.bytes(purgeable), caption: "purgeables (instantanés, caches…)", color: .orange)
            }
            Spacer()
            Text("Time Machine garde ces instantanés sur le Mac entre deux sauvegardes. macOS les supprime de lui-même quand la place manque, mais ils occupent de l'espace d'ici là.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 380, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if !selection.isEmpty {
                Button(selection.count == 1 ? "Supprimer…" : "Supprimer les \(selection.count)…", systemImage: "trash") {
                    confirming = store.snapshots.filter { selection.contains($0.id) }
                }
            }
            Button("Tout supprimer…") { confirmingAll = true }
                .disabled(store.snapshots.isEmpty)
            if store.isLoading { ProgressView().controlSize(.small) }
            Spacer()
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Button("Actualiser", systemImage: "arrow.clockwise") { Task { await store.reload() } }
                .labelStyle(.iconOnly)
        }
        .padding(10)
        .frame(height: 44)
    }
}
