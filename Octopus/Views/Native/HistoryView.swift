import SwiftUI

/// Historique des opérations de Mole, à partir de `mo history --json`.
struct HistoryView: View {
    let executable: String

    private enum Tab: String, CaseIterable, Identifiable {
        case sessions = "Opérations"
        case deletions = "Suppressions"
        var id: Self { self }
    }

    /// Les identifiants fournis par Mole ne sont pas toujours uniques : on numérote les lignes.
    private struct Row<Item>: Identifiable {
        let id: Int
        let item: Item
    }

    @State private var history: MoleHistory?
    @State private var tab: Tab = .sessions
    @State private var isLoading = false
    @State private var errorMessage: String?

    private var sessions: [Row<MoleHistory.Session>] {
        (history?.sessions ?? []).enumerated().map { Row(id: $0.offset, item: $0.element) }
    }

    private var deletions: [Row<MoleHistory.Deletion>] {
        (history?.deletions ?? []).enumerated().map { Row(id: $0.offset, item: $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Affichage", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if isLoading { ProgressView().controlSize(.small) }
                if let logs = history?.logs?.operations {
                    Button("Journal", systemImage: "doc.text.magnifyingglass") { Finder.reveal(logs) }
                        .help(String(localized: "Afficher les journaux de Mole dans le Finder"))
                }
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await load() } }
                    .labelStyle(.iconOnly)
                    .disabled(isLoading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            if let errorMessage {
                ErrorBanner(message: errorMessage) { Task { await load() } }
                    .padding(14)
                Spacer()
            } else if history == nil {
                ProgressView(String(localized: "Lecture de l'historique…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch tab {
                case .sessions: sessionsTable
                case .deletions: deletionsTable
                }
            }
        }
        .task { await load() }
    }

    // MARK: - Tables

    private var sessionsTable: some View {
        Table(sessions) {
            TableColumn("Commande") { row in
                Text("mo " + row.item.command).font(.callout.monospaced())
            }
            .width(min: 110, ideal: 130)
            TableColumn(String(localized: "Début")) { row in
                Text(Fmt.date(row.item.startDate)).monospacedDigit()
            }
            .width(min: 130, ideal: 150)
            TableColumn(String(localized: "Durée")) { row in
                Text(Fmt.duration(row.item.duration)).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn(String(localized: "Éléments")) { row in
                Text(Fmt.integer(row.item.items)).monospacedDigit()
            }
            .width(min: 60, ideal: 70)
            TableColumn("Taille") { row in
                Text(row.item.size ?? "—").monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn(String(localized: "Résultat")) { row in
                SessionResult(session: row.item)
            }
        }
        .overlay {
            if sessions.isEmpty {
                ContentUnavailableView(String(localized: "Aucune opération"), systemImage: "clock")
            }
        }
    }

    private var deletionsTable: some View {
        Table(deletions) {
            TableColumn("Date") { row in
                Text(Fmt.date(row.item.date)).monospacedDigit()
            }
            .width(min: 130, ideal: 150)
            TableColumn(String(localized: "Élément")) { row in
                Text((row.item.path as NSString).lastPathComponent)
                    .help(row.item.path)
                    .contextMenu {
                        Button(String(localized: "Afficher dans le Finder")) { Finder.reveal(row.item.path) }
                        Button(String(localized: "Copier le chemin")) { Finder.copy(row.item.path) }
                    }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Taille") { row in
                Text(Fmt.bytes(row.item.sizeBytes)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
            TableColumn("Destination") { row in
                if row.item.wentToTrash {
                    Label("Corbeille", systemImage: "trash")
                } else {
                    Label(String(localized: "Supprimé"), systemImage: "xmark.bin").foregroundStyle(.red)
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn(String(localized: "État")) { row in
                Text(row.item.status == "ok" ? "OK" : (row.item.status ?? "—"))
                    .foregroundStyle(row.item.status == "ok" ? Color.secondary : Color.orange)
            }
        }
        .overlay {
            if deletions.isEmpty {
                ContentUnavailableView(String(localized: "Aucune suppression"), systemImage: "trash")
            }
        }
    }

    // MARK: - Chargement

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            history = try await MoleCapture.decode(
                MoleHistory.self,
                executable: executable,
                arguments: ["history", "--json", "--limit", "200"]
            )
            errorMessage = nil
        } catch {
            errorMessage = String(localized: "Impossible de lire l'historique : \(error.localizedDescription)")
        }
    }
}

/// Résumé des actions d'une opération : supprimés, à la corbeille, ignorés, échecs.
private struct SessionResult: View {
    let session: MoleHistory.Session

    var body: some View {
        let actions = session.actions
        let parts: [(String, Int?)] = [
            (String(localized: "supprimés"), actions?.removed),
            (String(localized: "à la corbeille"), actions?.trashed),
            ("reconstruits", actions?.rebuilt),
            (String(localized: "ignorés"), actions?.skipped),
        ]
        let summary = parts
            .compactMap { label, count in (count ?? 0) > 0 ? "\(count!) \(label)" : nil }
            .joined(separator: " · ")
        let failures = (actions?.failed ?? 0) + (session.failedTasks ?? 0)

        HStack(spacing: 6) {
            if failures > 0 {
                Label(failures > 1 ? String(localized: "\(failures) échecs") : String(localized: "1 échec"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(summary.isEmpty ? String(localized: "Rien à faire") : summary)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}
