import SwiftUI

/// Hôtes connus (~/.ssh/known_hosts) : recherche et suppression.
///
/// Utile quand un serveur est réinstallé : ssh refuse alors la connexion parce que
/// sa clé a changé, et il faut supprimer l'ancienne.
struct KnownHostsView: View {
    let store: KnownHostsStore

    @State private var search = ""
    @State private var selection = Set<KnownHost.ID>()
    @State private var hostToRemove = ""
    @State private var confirmingRemoval = false

    private var filtered: [KnownHost] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var hashedCount: Int { store.entries.filter { $0.hosts == nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Rechercher", text: $search, prompt: Text("Rechercher un hôte"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Supprimer la sélection", systemImage: "trash") { confirmingRemoval = true }
                    .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Table(filtered, selection: $selection) {
                TableColumn("Hôte") { entry in
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .foregroundStyle(entry.hosts == nil ? Color.secondary : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let marker = entry.marker {
                            Badge(text: marker, color: .orange)
                        }
                    }
                }
                TableColumn("Type de clé") { entry in
                    Text(entry.shortKeyType).font(.callout.monospaced())
                }
                .width(min: 90, ideal: 120)
                TableColumn("Ligne") { entry in
                    Text("\(entry.line)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 40, ideal: 50)
            }
            .overlay {
                if store.entries.isEmpty {
                    ContentUnavailableView("Aucun hôte connu", systemImage: "network",
                                           description: Text("~/.ssh/known_hosts est vide ou absent."))
                }
            }

            Divider()
            footer
        }
        .confirmationDialog(
            selection.count == 1 ? "Supprimer cette entrée ?" : "Supprimer \(selection.count) entrées ?",
            isPresented: $confirmingRemoval
        ) {
            Button("Supprimer", role: .destructive) {
                store.remove(lines: selection)
                selection.removeAll()
            }
        } message: {
            Text("À la prochaine connexion, ssh te demandera de confirmer la clé du serveur. Une copie du fichier est gardée dans known_hosts.old.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Supprimer toutes les clés d'un hôte :")
                TextField("Hôte", text: $hostToRemove, prompt: Text("serveur.lan ou 192.168.1.10"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(removeHost)
                Button("Supprimer", action: removeHost)
                    .disabled(hostToRemove.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                if hashedCount > 0 {
                    Text("\(hashedCount) entrée\(hashedCount > 1 ? "s" : "") hachée\(hashedCount > 1 ? "s" : "") : leur nom n'est pas lisible, mais ce champ les retrouve aussi.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let message = store.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func removeHost() {
        let host = hostToRemove
        Task {
            await store.remove(host: host)
            hostToRemove = ""
        }
    }
}
