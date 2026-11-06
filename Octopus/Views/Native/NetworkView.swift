import AppKit
import SwiftUI

/// Outils réseau : aperçu de la connexion, diagnostic et fichier /etc/hosts.
struct NetworkView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case overview = "Aperçu"
        case hosts = "Fichier hosts"
        var id: Self { self }
    }

    @State private var tab: Tab = .overview
    @State private var network = NetworkStore()
    @State private var hosts = HostsStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()

            switch tab {
            case .overview: NetworkOverview(store: network)
            case .hosts: HostsEditor(store: hosts)
            }
        }
        .task {
            hosts.reload()
            await network.reload()
        }
    }
}

// MARK: - Aperçu

private struct NetworkOverview: View {
    let store: NetworkStore
    @Environment(TerminalSession.self) private var session
    @State private var target = ""
    @State private var copied: String?

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    if let message = store.message {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Actualiser", systemImage: "arrow.clockwise") { Task { await store.reload() } }
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    connectionCard
                    interfacesCard
                    publicIPCard
                    diagnosticCard
                }
            }
            .padding(20)
        }
    }

    private var connectionCard: some View {
        DashboardCard(title: String(localized: "Connexion"), symbol: "network") {
            let main = store.interfaces.first { $0.device == store.defaultInterface }
            ValueRow(label: String(localized: "Interface principale"), value: main.map { "\($0.title) (\($0.device))" } ?? store.defaultInterface ?? "—")
            if let ip = main?.ipv4.first { copyRow(String(localized: "Adresse IP"), ip) }
            if let gateway = store.gateway { copyRow(String(localized: "Routeur"), gateway) }
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "Serveurs DNS")).font(.callout).foregroundStyle(.secondary)
                if store.dnsServers.isEmpty {
                    Text("—")
                } else {
                    Text(store.dnsServers.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            Divider()
            HStack {
                Button(String(localized: "Vider le cache DNS")) { Task { await store.flushDNS() } }
                Text(String(localized: "Utile après un changement de DNS ou de /etc/hosts."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var interfacesCard: some View {
        DashboardCard(title: String(localized: "Interfaces actives"), symbol: "cable.connector") {
            ForEach(store.interfaces) { interface in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: interface)).foregroundStyle(.secondary).frame(width: 16)
                        Text(interface.title).fontWeight(.medium)
                        Text(interface.device).font(.caption.monospaced()).foregroundStyle(.tertiary)
                        if interface.device == store.defaultInterface { Badge(text: "principale", color: .green) }
                    }
                    ForEach(interface.ipv4 + interface.ipv6, id: \.self) { ip in
                        Text(ip)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 22)
                    }
                }
            }
            if store.interfaces.isEmpty {
                Text(String(localized: "Aucune interface connectée")).foregroundStyle(.secondary)
            }
        }
    }

    private var publicIPCard: some View {
        DashboardCard(title: String(localized: "IP publique"), symbol: "globe") {
            Text(String(localized: "L'adresse sous laquelle Internet voit ton Mac (celle du routeur ou du VPN). Obtenue auprès du service public ipify.org."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let v4 = store.publicIPv4 { copyRow("IPv4", v4) }
            if let v6 = store.publicIPv6 { copyRow("IPv6", v6) }
            HStack {
                Button(store.publicIPv4 == nil && store.publicIPv6 == nil ? String(localized: "Afficher l'IP publique") : "Actualiser") {
                    Task { await store.fetchPublicIP() }
                }
                .disabled(store.isFetchingPublicIP)
                if store.isFetchingPublicIP { ProgressView().controlSize(.small) }
            }
        }
    }

    private var diagnosticCard: some View {
        DashboardCard(title: String(localized: "Diagnostic"), symbol: "stethoscope") {
            TextField(String(localized: "Hôte"), text: $target, prompt: Text(String(localized: "apple.com, 192.168.1.1…")))
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Ping") { run("ping", NetworkStore.pingCommand) }
                Button("Traceroute") { run("traceroute", NetworkStore.tracerouteCommand) }
                Button(String(localized: "Résolution DNS")) { run("dscacheutil", NetworkStore.lookupCommand) }
            }
            .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty || session.isRunning)
            Text(String(localized: "Les résultats s'affichent dans le terminal, en bas de la fenêtre."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
            Button {
                Finder.copy(value)
                copied = value
            } label: {
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copier")
        }
        .font(.callout)
    }

    private func icon(for interface: NetworkInterface) -> String {
        if interface.isVPN { return "lock.shield" }
        switch interface.portName ?? "" {
        case "Wi-Fi": return "wifi"
        case let name where name.contains("Thunderbolt"): return "bolt.horizontal"
        case let name where name.contains("Ethernet") || name.contains("LAN"): return "cable.connector.horizontal"
        default: return "network"
        }
    }

    private func run(_ title: String, _ command: (String) -> String) {
        let host = target.trimmingCharacters(in: .whitespaces)
        session.start(title: "\(title) \(host)", commandLine: command(host))
    }
}

// MARK: - /etc/hosts

private struct HostsEditor: View {
    let store: HostsStore
    @State private var textMode = false
    @State private var text = ""
    @State private var selection: HostsEntry.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Mode", selection: Binding(get: { textMode }, set: { switchMode(text: $0) })) {
                    Text("Tableau").tag(false)
                    Text("Texte").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if !textMode {
                    Button("Ajouter", systemImage: "plus") {
                        store.add(HostsEntry(address: "127.0.0.1", names: "nouveau.local", comment: "", enabled: true))
                    }
                    Button("Supprimer", systemImage: "minus") {
                        if let selection { store.remove(selection) }
                        selection = nil
                    }
                    .disabled(selectedEntry == nil || selectedEntry?.isSystem == true)
                }
                Spacer()
                Button(String(localized: "Afficher dans le Finder"), systemImage: "folder") { Finder.reveal(HostsFile.url.path) }
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if textMode {
                TextEditor(text: $text)
                    .font(.callout.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: text) { _, newText in store.setText(newText) }
            } else {
                table
            }

            Divider()
            saveBar
        }
    }

    private var selectedEntry: HostsEntry? { store.file.entries.first { $0.id == selection } }

    private var table: some View {
        Table(store.file.entries, selection: $selection) {
            TableColumn("Actif") { entry in
                Toggle("", isOn: binding(entry, \.enabled))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(entry.isSystem)
            }
            .width(44)
            TableColumn("Adresse") { entry in
                HStack(spacing: 4) {
                    if entry.isSystem { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary) }
                    TextField("", text: binding(entry, \.address))
                        .font(.body.monospaced())
                        .foregroundStyle(entry.isValid ? Color.primary : Color.red)
                        .disabled(entry.isSystem)
                }
            }
            .width(min: 120, ideal: 160)
            TableColumn("Noms") { entry in
                TextField("", text: binding(entry, \.names))
                    .disabled(entry.isSystem)
            }
            .width(min: 180, ideal: 320)
            TableColumn("Commentaire") { entry in
                TextField("", text: binding(entry, \.comment))
                    .foregroundStyle(.secondary)
                    .disabled(entry.isSystem)
            }
        }
        .textFieldStyle(.plain)
        .overlay {
            if store.file.entries.isEmpty {
                ContentUnavailableView(String(localized: "Aucune entrée"), systemImage: "list.bullet.rectangle")
            }
        }
    }

    private var saveBar: some View {
        HStack {
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text(store.hasChanges
                     ? String(localized: "Modifications non enregistrées")
                     : String(localized: "Une entrée désactivée est conservée en commentaire. Les entrées de macOS (localhost) sont verrouillées."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Annuler les modifications")) {
                store.discard()
                text = store.file.serialized()
            }
            .disabled(!store.hasChanges)
            Button("Enregistrer") { Task { await store.save() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.hasChanges || store.file.entries.contains { !$0.isValid })
        }
        .padding(12)
    }

    private func binding<Value>(_ entry: HostsEntry, _ keyPath: WritableKeyPath<HostsEntry, Value>) -> Binding<Value> {
        Binding(
            get: { store.file.entries.first { $0.id == entry.id }?[keyPath: keyPath] ?? entry[keyPath: keyPath] },
            set: { newValue in
                var updated = store.file.entries.first { $0.id == entry.id } ?? entry
                updated[keyPath: keyPath] = newValue
                store.update(updated)
            }
        )
    }

    private func switchMode(text toText: Bool) {
        if toText { text = store.file.serialized() }
        textMode = toText
    }
}
