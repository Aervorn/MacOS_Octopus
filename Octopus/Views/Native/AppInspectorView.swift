import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inspecteur d'app : on glisse une app, on voit d'où elle vient et ce qu'elle peut faire.
struct AppInspectorView: View {
    @State private var report: AppReport?
    @State private var isInspecting = false
    @State private var isTargeted = false
    @State private var quarantineMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 14, alignment: .top)]

    var body: some View {
        Group {
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(report)
                        LazyVGrid(columns: columns, spacing: 14) {
                            signatureCard(report)
                            gatekeeperCard(report)
                            entitlementsCard(report)
                            if !report.privacyUsages.isEmpty { privacyCard(report) }
                            componentsCard(report)
                        }
                    }
                    .padding(20)
                }
                .overlay { if isInspecting { ProgressView().controlSize(.large) } }
            } else {
                dropZone
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension == "app" }) ?? urls.first else { return false }
            inspect(url)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    // MARK: - Zone de dépôt

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: isInspecting ? "hourglass" : "app.badge.checkmark")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            Text(isInspecting ? String(localized: "Analyse en cours…") : String(localized: "Glisse une app ici")).font(.title2.bold())
            Text(String(localized: "Octopus vérifie sa signature, sa notarisation par Apple, sa quarantaine, les droits qu'elle demande et ce qu'elle installe en arrière-plan."))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(String(localized: "Choisir une app…")) { chooseApp() }
                .buttonStyle(.borderedProminent)
                .disabled(isInspecting)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(24)
        }
    }

    // MARK: - En-tête

    private func header(_ report: AppReport) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: report.url.path))
                .resizable()
                .frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.name).font(.title.bold())
                    if let version = report.version {
                        Text(version).foregroundStyle(.secondary)
                    }
                }
                Label(report.verdictTitle, systemImage: verdictSymbol(report.verdict))
                    .foregroundStyle(verdictColor(report.verdict))
                    .font(.headline)
                Text([report.bundleID, architectureText(report.architectures), report.sizeBytes.map { Fmt.bytes($0) },
                      report.minimumSystem.map { "macOS \($0)+" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button(String(localized: "Autre app…")) { chooseApp() }
                Button(String(localized: "Afficher dans le Finder")) { Finder.reveal(report.url.path) }
            }
        }
    }

    // MARK: - Cartes

    private func signatureCard(_ report: AppReport) -> some View {
        DashboardCard(title: String(localized: "Signature"), symbol: "signature") {
            ValueRow(label: String(localized: "Signée par"), value: report.signature.title)
            if let team = report.teamID { ValueRow(label: String(localized: "Équipe"), value: team) }
            if let valid = report.signatureValid {
                ValueRow(label: String(localized: "Intégrité"), value: valid ? String(localized: "Intacte") : String(localized: "Modifiée depuis la signature"))
                if let error = report.signatureError, !valid {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            ValueRow(label: String(localized: "Runtime renforcé"), value: report.hardenedRuntime ? String(localized: "Oui") : String(localized: "Non"))
            if let date = report.signedAt { ValueRow(label: String(localized: "Horodatage"), value: date) }
            if report.authorities.count > 1 {
                Text(report.authorities.joined(separator: " → "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func gatekeeperCard(_ report: AppReport) -> some View {
        DashboardCard(title: String(localized: "Gatekeeper et quarantaine"), symbol: "hand.raised") {
            HStack {
                Image(systemName: report.gatekeeper.isAccepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(report.gatekeeper.isAccepted ? Color.green : Color.orange)
                Text(report.gatekeeper.title)
            }
            if let quarantine = report.quarantine {
                VStack(alignment: .leading, spacing: 4) {
                    Label(String(localized: "En quarantaine"), systemImage: "exclamationmark.shield")
                        .foregroundStyle(.orange)
                    Text([String(localized: "Téléchargée"), quarantine.agent.map { "avec \($0)" },
                          quarantine.date.map { "le \($0.formatted(date: .abbreviated, time: .shortened))" }]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(report.gatekeeper.isAccepted
                         ? String(localized: "macOS a déjà vérifié l'app ou la vérifiera à la prochaine ouverture.")
                         : String(localized: "macOS bloquera son ouverture. Ne retire la quarantaine que si tu fais confiance à sa provenance (une app que tu as compilée, par exemple)."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(String(localized: "Retirer la quarantaine")) { removeQuarantine(report) }
                        .padding(.top, 2)
                }
            } else {
                Label(String(localized: "Pas de quarantaine"), systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }
            if let message = quarantineMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func entitlementsCard(_ report: AppReport) -> some View {
        DashboardCard(title: String(localized: "Droits (entitlements)"), symbol: "key.viewfinder") {
            if report.entitlements.isEmpty {
                Text(String(localized: "Aucun droit particulier déclaré.")).foregroundStyle(.secondary)
            } else {
                let sandboxed = report.entitlements.contains { $0.key == "com.apple.security.app-sandbox" && $0.value == "oui" }
                Label(sandboxed ? String(localized: "Isolée dans un bac à sable") : String(localized: "Pas de bac à sable : accès étendu au Mac"),
                      systemImage: sandboxed ? "shippingbox.fill" : "shippingbox")
                    .foregroundStyle(sandboxed ? Color.green : Color.secondary)
                ForEach(report.entitlements.filter { $0.key != "com.apple.security.app-sandbox" }) { entitlement in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: entitlement.isSensitive ? "exclamationmark.triangle.fill" : "circle.fill")
                            .font(.system(size: entitlement.isSensitive ? 11 : 5))
                            .foregroundStyle(entitlement.isSensitive ? Color.orange : Color.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entitlement.description ?? entitlement.key)
                                .foregroundStyle(entitlement.isSensitive ? Color.orange : Color.primary)
                            if entitlement.description != nil || (entitlement.value != "oui") {
                                Text(entitlement.value == "oui" ? entitlement.key : "\(entitlement.key) : \(entitlement.value)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                }
            }
        }
    }

    private func privacyCard(_ report: AppReport) -> some View {
        DashboardCard(title: String(localized: "Autorisations qu'elle peut demander"), symbol: "hand.raised.square") {
            ForEach(report.privacyUsages) { usage in
                VStack(alignment: .leading, spacing: 1) {
                    Text(usage.title).font(.callout.weight(.medium))
                    if !usage.text.isEmpty {
                        Text(String(localized: "« \(usage.text) »"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func componentsCard(_ report: AppReport) -> some View {
        DashboardCard(title: String(localized: "Composants"), symbol: "square.stack.3d.down.right") {
            ValueRow(label: String(localized: "Provenance"), value: report.isFromAppStore ? String(localized: "Mac App Store") : String(localized: "Hors App Store"))
            ValueRow(label: String(localized: "Mises à jour"), value: report.usesSparkle ? String(localized: "Sparkle (automatiques)") : (report.isFromAppStore ? String(localized: "App Store") : "—"))
            ValueRow(label: String(localized: "Frameworks embarqués"), value: "\(report.frameworkCount)")
            componentList(String(localized: "Lancées à l'ouverture de session"), report.loginItems)
            componentList(String(localized: "Services en arrière-plan"), report.launchServices)
            componentList(String(localized: "Extensions système"), report.systemExtensions)
        }
    }

    @ViewBuilder
    private func componentList(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.callout).foregroundStyle(.secondary)
                ForEach(items, id: \.self) { item in
                    Text(item).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application, .executable]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            inspect(url)
        }
    }

    private func inspect(_ url: URL) {
        quarantineMessage = nil
        isInspecting = true
        Task {
            report = await AppInspector.inspect(url)
            isInspecting = false
        }
    }

    private func removeQuarantine(_ report: AppReport) {
        Task {
            do {
                try await AppInspector.removeQuarantine(report.url)
                quarantineMessage = String(localized: "Quarantaine retirée.")
                self.report = await AppInspector.inspect(report.url)
            } catch {
                quarantineMessage = error.localizedDescription
            }
        }
    }

    private func architectureText(_ architectures: [String]) -> String? {
        let set = Set(architectures)
        if set.contains("arm64") && set.contains("x86_64") { return "Universelle" }
        if set.contains("arm64") || set.contains("arm64e") { return "Apple Silicon" }
        if set.contains("x86_64") { return "Intel (Rosetta)" }
        return nil
    }

    private func verdictSymbol(_ verdict: AppReport.Verdict) -> String {
        switch verdict {
        case .trusted: "checkmark.seal.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }

    private func verdictColor(_ verdict: AppReport.Verdict) -> Color {
        switch verdict {
        case .trusted: .green
        case .caution: .orange
        case .danger: .red
        }
    }
}
