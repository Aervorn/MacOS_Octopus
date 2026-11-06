import AppKit
import SwiftUI

/// Gestionnaire SSH : clés, hôtes de ~/.ssh/config et hôtes connus.
struct SSHView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case keys = "Clés"
        case hosts = "Hôtes"
        case known = "Hôtes connus"
        var id: Self { self }
    }

    @Environment(TerminalSession.self) private var session
    @State private var tab: Tab = .keys
    @State private var keyStore = SSHKeyStore()
    @State private var configStore = SSHConfigStore()
    @State private var knownHosts = KnownHostsStore()
    @State private var onePassword = OnePasswordMonitor()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                OnePasswordBadge(monitor: onePassword)
                Button("Afficher ~/.ssh", systemImage: "folder") {
                    NSWorkspace.shared.open(SSHKeyStore.directory)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .keys:
                SSHKeysView(store: keyStore,
                            hostAliases: configStore.file.blocks.filter(\.isConcreteHost).map(\.header))
            case .hosts: SSHHostsView(store: configStore, keys: keyStore.keys)
            case .known: KnownHostsView(store: knownHosts)
            }
        }
        .task {
            configStore.reload()
            knownHosts.reload()
            await keyStore.reload()
        }
        .task { await onePassword.watch() }
        // 1Password vient de démarrer ou de s'arrêter : les clés de l'agent changent
        .onChange(of: onePassword.isActive) { _, _ in
            Task { await keyStore.reload() }
        }
        // Après une commande dans le terminal (nouvelle clé, phrase de passe, agent…)
        .onChange(of: session.isRunning) { _, running in
            guard !running else { return }
            Task { await keyStore.reload() }
            knownHosts.reload()
        }
    }
}

/// État de l'agent 1Password, avec un bouton pour lancer l'app quand il ne répond pas.
private struct OnePasswordBadge: View {
    let monitor: OnePasswordMonitor

    var body: some View {
        switch monitor.state {
        case .notUsed:
            EmptyView()
        case .active(let count):
            Label(count == 0 ? "1Password actif" : "1Password actif · \(count) clé\(count > 1 ? "s" : "")",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .appNotRunning:
            HStack(spacing: 6) {
                Label("1Password fermé", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .help("L'agent SSH de 1Password ne fonctionne que lorsque l'app est lancée.")
                Button("Ouvrir") { monitor.openApp() }
                    .controlSize(.small)
            }
        case .agentUnavailable:
            HStack(spacing: 6) {
                Label("Agent 1Password inactif", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .help("1Password est lancé mais son agent ne répond pas : vérifie Réglages › Développeur › « Utiliser l'agent SSH ».")
                Button("Ouvrir") { monitor.openApp() }
                    .controlSize(.small)
            }
        }
    }
}
