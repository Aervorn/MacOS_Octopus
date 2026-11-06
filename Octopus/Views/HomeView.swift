import AppKit
import SwiftUI

/// Accueil : état de Mole, santé et sécurité du Mac en un coup d'œil, puis toutes les fonctions.
struct HomeView: View {
    let manifest: CommandManifest
    let select: (String) -> Void

    @Environment(MoleService.self) private var mole
    @Environment(TerminalSession.self) private var session
    @Environment(Permissions.self) private var permissions
    @State private var status: MoleStatus?
    @State private var security = SecurityChecker()

    private let summaryColumns = [GridItem(.adaptive(minimum: 260), spacing: 14, alignment: .top)]
    private let tileColumns = [GridItem(.adaptive(minimum: 230), spacing: 10, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                LazyVGrid(columns: summaryColumns, spacing: 14) {
                    moleCard
                    healthCard
                    securityCard
                    permissionsCard
                }
                ForEach(manifest.categories) { category in
                    let commands = manifest.commands(in: category)
                    if !commands.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(category.title, systemImage: category.symbol)
                                .font(.headline)
                                .foregroundStyle(category.tint)
                            LazyVGrid(columns: tileColumns, spacing: 10) {
                                ForEach(commands) { command in
                                    FeatureTile(command: command, tint: category.tint) { select(command.id) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task(id: mole.executablePath) {
            guard let executable = mole.executablePath else { return }
            status = try? await MoleCapture.decode(MoleStatus.self, executable: executable, arguments: ["status", "--json"])
        }
        .task { await security.checkAll() }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Octopus").font(.largeTitle.bold())
                Text("Nettoyage, apps, sécurité et outils système pour ton Mac.")
                    .foregroundStyle(.secondary)
                Text("Certaines fonctions sont basées sur l'utilitaire en ligne de commande **Mole**.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Cartes de synthèse

    private var moleCard: some View {
        DashboardCard(title: "Mole", symbol: "hammer") {
            switch mole.state {
            case .checking:
                ProgressView().controlSize(.small)
            case .missing:
                Label("Non installé", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("La plupart des fonctions de nettoyage en ont besoin.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Installer Mole") {
                    session.start(title: "Installation de Mole", commandLine: MoleService.installCommand())
                }
                .disabled(session.isRunning)
            case .installed(_, let version, let method):
                BigValue(value: version ?? "?", caption: method == .script ? "installé avec le script officiel" : "installé avec Homebrew")
                if mole.updateAvailable, let latest = mole.latestVersion {
                    Label("Version \(latest) disponible", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    if let command = mole.updateCommand(arguments: ["update"]) {
                        Button("Mettre à jour") {
                            session.start(title: "Mise à jour de Mole", commandLine: command)
                        }
                        .disabled(session.isRunning)
                    }
                } else if mole.latestVersion != nil {
                    Label("À jour", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Dernière version inconnue (hors ligne ?)", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var healthCard: some View {
        DashboardCard(title: "Santé du Mac", symbol: "heart.text.square") {
            if let status {
                HStack(alignment: .top, spacing: 0) {
                    let score = Double(status.healthScore ?? 0)
                    RingGauge(fraction: score / 100, value: "\(Int(score))", label: "Santé",
                              color: healthColor(status.healthScore))
                    if let disk = status.disks?.first(where: { $0.mount == "/" }), let used = disk.usedPercent {
                        RingGauge(fraction: used / 100, value: Fmt.percent(used), label: "Disque",
                                  color: LevelBar.color(for: used / 100))
                    }
                    if let used = status.memory?.usedPercent {
                        RingGauge(fraction: used / 100, value: Fmt.percent(used), label: "Mémoire",
                                  color: LevelBar.color(for: used / 100))
                    }
                }
                if let message = status.healthScoreMsg, !message.isEmpty {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                Button("État du système") { select("status") }
            } else if mole.executablePath == nil {
                Text("Disponible une fois Mole installé.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var securityCard: some View {
        DashboardCard(title: "Sécurité", symbol: "checkmark.shield") {
            if security.checks.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                let problems = security.problemCount
                Label(problems == 0 ? "Tout est en ordre" : (problems == 1 ? "1 point à vérifier" : "\(problems) points à vérifier"),
                      systemImage: problems == 0 ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(problems == 0 ? Color.green : Color.orange)
                Text("SIP, Gatekeeper, FileVault, XProtect, démarrage sécurisé…")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Vérifications") { select("security") }
            }
        }
    }

    private var permissionsCard: some View {
        DashboardCard(title: "Autorisations", symbol: "lock.shield") {
            switch permissions.fullDiskAccess {
            case .granted:
                Label("Accès complet au disque accordé", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing:
                Label("Accès complet au disque manquant", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("Mole ne peut pas nettoyer les dossiers protégés.").font(.callout).foregroundStyle(.secondary)
                Button("Autoriser…") { Permissions.open(Permissions.fullDiskAccessURL) }
            case .unknown:
                Label("Accès complet au disque : état inconnu", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            }
            SettingsLink { Text("Réglages des autorisations…") }
        }
    }

    private func healthColor(_ score: Int?) -> Color {
        switch score ?? 0 {
        case 80...: .green
        case 50..<80: .orange
        default: .red
        }
    }
}

/// Jauge circulaire : anneau rempli selon `fraction` (0…1), valeur au centre, libellé dessous.
private struct RingGauge: View {
    let fraction: Double
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(max(fraction, 0), 1))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(value)
                    .font(.system(.callout, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .frame(width: 64, height: 64)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Tuile d'une fonction : icône sur pastille colorée, titre et description.
private struct FeatureTile: View {
    let command: CommandManifest.Command
    let tint: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: command.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(command.title)).fontWeight(.medium)
                    if let subtitle = command.subtitle {
                        Text(LocalizedStringKey(subtitle))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(isHovering ? tint.opacity(0.12) : Color.secondary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(isHovering ? 0.6 : 0.2)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
