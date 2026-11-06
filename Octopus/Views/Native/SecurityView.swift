import AppKit
import SwiftUI

/// Vérifications de sécurité du Mac, dans l'esprit de SilentKnight.
struct SecurityView: View {
    @Environment(TerminalSession.self) private var session
    @State private var checker = SecurityChecker()
    @State private var confirmingInstall: PendingUpdate?

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(checker.checks) { CheckCard(check: $0) }
                }
                xprotectActions
                updatesSection
            }
            .padding(20)
        }
        // Vérifications et recherche de mises à jour en parallèle, dès l'ouverture
        .task { await checkEverything(force: false) }
        .confirmationDialog(
            "Installer « \(confirmingInstall?.title ?? "") » ?",
            isPresented: Binding(get: { confirmingInstall != nil }, set: { if !$0 { confirmingInstall = nil } }),
            presenting: confirmingInstall
        ) { update in
            Button("Installer") { install(update) }
        } message: { update in
            Text(update.needsRestart
                 ? "Cette mise à jour demande de redémarrer le Mac."
                 : "L'installation demande ton mot de passe administrateur ou Touch ID.")
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: headerSymbol)
                .font(.system(size: 38))
                .foregroundStyle(color(for: checker.overallLevel))
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle).font(.title2.bold())
                if let date = checker.lastCheck {
                    Text("Dernière vérification : \(date.formatted(date: .omitted, time: .shortened))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if checker.isChecking { ProgressView().controlSize(.small) }
            Button("Tout vérifier", systemImage: "arrow.clockwise") {
                Task { await checkEverything(force: true) }
            }
            .disabled(checker.isChecking || checker.isListingUpdates)
        }
    }

    private var headerTitle: String {
        if checker.checks.isEmpty { return "Vérification en cours…" }
        switch checker.problemCount {
        case 0: return "Tout est en ordre"
        case 1: return "1 point à vérifier"
        default: return "\(checker.problemCount) points à vérifier"
        }
    }

    private var headerSymbol: String {
        switch checker.overallLevel {
        case .good, .info: "checkmark.shield.fill"
        case .warning: "exclamationmark.shield.fill"
        case .bad: "xmark.shield.fill"
        case .unknown: "shield"
        }
    }

    // MARK: - XProtect

    private var xprotectActions: some View {
        DashboardCard(title: "XProtect à jour ?", symbol: "icloud.and.arrow.down") {
            Text("Depuis macOS 15, XProtect se met aussi à jour par iCloud. Ces commandes demandent les droits administrateur et s'exécutent dans le terminal.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Vérifier sur iCloud") {
                    run(title: "sudo xprotect check", "sudo /usr/bin/xprotect check")
                }
                Button("Mettre à jour XProtect") {
                    run(title: "sudo xprotect update", "sudo /usr/bin/xprotect update")
                }
            }
            .disabled(session.isRunning || !FileManager.default.isExecutableFile(atPath: "/usr/bin/xprotect"))
        }
    }

    // MARK: - Mises à jour

    private var updatesSection: some View {
        DashboardCard(title: "Mises à jour en attente", symbol: "arrow.down.circle") {
            HStack {
                Text("Interroge Apple : mises à jour de sécurité, données XProtect et versions de macOS.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if checker.isListingUpdates {
                    ProgressView().controlSize(.small)
                    Text("Recherche en cours…").font(.callout).foregroundStyle(.secondary)
                }
                Button(checker.updates == nil ? "Rechercher" : "Rechercher à nouveau") {
                    Task { await checker.listUpdates(force: true) }
                }
                .disabled(checker.isListingUpdates)
            }

            if let error = checker.updatesError {
                ErrorBanner(message: error) { Task { await checker.listUpdates(force: true) } }
            } else if let updates = checker.updates {
                if updates.isEmpty {
                    Label("Aucune mise à jour en attente", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                ForEach(updates) { update in
                    HStack {
                        Image(systemName: update.isMacOS ? "apple.logo" : "shield")
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(update.title)
                            Text([update.version.map { "Version \($0)" }, update.needsRestart ? "redémarrage" : nil]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if update.isMacOS {
                            Button("Réglages Système") { openSoftwareUpdate() }
                        } else {
                            Button("Installer") { confirmingInstall = update }
                                .disabled(session.isRunning)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: - Actions

    private func checkEverything(force: Bool) async {
        async let checks: Void = checker.checkAll()
        async let updates: Void = checker.listUpdates(force: force)
        _ = await (checks, updates)
    }

    private func run(title: String, _ commandLine: String) {
        session.start(title: title, commandLine: commandLine)
    }

    private func install(_ update: PendingUpdate) {
        run(title: "softwareupdate --install \(update.label)",
            "sudo /usr/sbin/softwareupdate --install \(Shell.quote(update.label))")
    }

    private func openSoftwareUpdate() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    private func color(for level: SecurityCheck.Level) -> Color {
        CheckCard.color(for: level)
    }
}

/// Carte d'une vérification : voyant coloré, valeur, explication.
private struct CheckCard: View {
    let check: SecurityCheck

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: check.symbol)
                .font(.title2)
                .foregroundStyle(Self.color(for: check.level))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.color(for: check.level))
                        .frame(width: 8, height: 8)
                    Text(check.value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .textSelection(.enabled)
                }
                if let detail = check.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    static func color(for level: SecurityCheck.Level) -> Color {
        switch level {
        case .good: .green
        case .info: .blue
        case .warning: .orange
        case .bad: .red
        case .unknown: .gray
        }
    }
}
