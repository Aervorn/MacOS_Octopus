import AppKit
import SwiftUI

/// Ports TCP en écoute : quel processus occupe quel port, et l'arrêter si besoin.
struct PortsView: View {
    @Environment(TerminalSession.self) private var session
    @State private var scanner = PortScanner()
    @State private var search = ""
    @State private var selection: ListeningPort.ID?
    @State private var autoRefresh = true
    @State private var stopping: (port: ListeningPort, force: Bool)?

    private var filtered: [ListeningPort] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return scanner.ports }
        return scanner.ports.filter {
            String($0.port).hasPrefix(query)
                || $0.processName.localizedCaseInsensitiveContains(query)
                || ($0.wellKnownService?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.commandLine?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var selectedPort: ListeningPort? { scanner.ports.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Table(filtered, selection: $selection) {
                TableColumn("Port") { port in
                    Text(String(port.port))
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                .width(min: 60, ideal: 70, max: 90)

                TableColumn("Processus") { port in
                    ProcessCell(port: port)
                }
                .width(min: 160, ideal: 220)

                TableColumn("Commande") { port in
                    Text(port.displayCommand)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(port.commandLine ?? port.executablePath ?? "")
                        .textSelection(.enabled)
                }
                .width(min: 200, ideal: 380)

                TableColumn("Écoute sur") { port in
                    HStack(spacing: 6) {
                        Image(systemName: port.isLocalOnly ? "lock" : "network")
                            .foregroundStyle(port.isLocalOnly ? Color.secondary : Color.orange)
                        Text(port.addressSummary)
                    }
                    .help(port.isLocalOnly
                          ? "Accessible uniquement depuis ce Mac"
                          : "Accessible depuis le réseau : \(port.addresses.joined(separator: ", "))")
                }
                .width(min: 140, ideal: 170)

                TableColumn("PID") { port in
                    Text(String(port.pid)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 50, ideal: 60, max: 80)
            }
            .contextMenu(forSelectionType: ListeningPort.ID.self) { ids in
                if let id = ids.first, let port = scanner.ports.first(where: { $0.id == id }) {
                    menuItems(port)
                }
            } primaryAction: { ids in
                if let id = ids.first, let port = scanner.ports.first(where: { $0.id == id }) {
                    openInBrowser(port)
                }
            }
            .overlay {
                if scanner.ports.isEmpty && scanner.lastScan != nil {
                    ContentUnavailableView("Aucun port en écoute", systemImage: "network.slash",
                                           description: Text("Aucun de tes processus n'attend de connexion TCP."))
                } else if !scanner.ports.isEmpty && filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            Divider()
            footer
        }
        .task { await scanner.scan() }
        .task(id: autoRefresh) {
            // Rafraîchissement toutes les 3 s, arrêté quand la vue disparaît
            while autoRefresh && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard autoRefresh, !Task.isCancelled else { break }
                await scanner.scan()
            }
        }
        .confirmationDialog(
            stopping.map { "\($0.force ? "Forcer l'arrêt de" : "Arrêter") « \($0.port.processName) » ?" } ?? "",
            isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
            presenting: stopping
        ) { item in
            Button(item.force ? "Forcer l'arrêt" : "Arrêter", role: .destructive) {
                Task { await scanner.stop(item.port, force: item.force) }
            }
        } message: { item in
            Text(item.force
                 ? "Le processus est tué immédiatement, sans pouvoir enregistrer quoi que ce soit."
                 : "Le processus reçoit une demande de fermeture (comme Ctrl-C) et peut s'arrêter proprement.")
        }
    }

    // MARK: - Barres

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Rechercher", text: $search, prompt: Text("Port, processus ou commande (ex. 3000, node)"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Spacer()
            if let port = selectedPort {
                Button("Ouvrir dans le navigateur", systemImage: "safari") { openInBrowser(port) }
                Button("Arrêter", systemImage: "stop.circle") { stopping = (port, false) }
            }
            Toggle("Processus système", isOn: Binding(
                get: { scanner.includeSystem },
                set: { newValue in
                    scanner.includeSystem = newValue
                    // Pas d'actualisation automatique en mode administrateur :
                    // chaque passage redemanderait l'autorisation une fois celle-ci expirée.
                    if newValue { autoRefresh = false }
                    Task { await scanner.scan() }
                }
            ))
            .toggleStyle(.checkbox)
            .help("Affiche aussi les processus de root et des autres utilisateurs (Touch ID ou mot de passe)")
            Toggle("Actualiser en continu", isOn: $autoRefresh)
                .toggleStyle(.checkbox)
                .disabled(scanner.includeSystem)
            Button("Actualiser", systemImage: "arrow.clockwise") { Task { await scanner.scan() } }
                .labelStyle(.iconOnly)
                .disabled(scanner.isScanning)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text(scanner.includeSystem
                 ? "Processus de tous les utilisateurs, système compris."
                 : "Seuls tes processus sont visibles. Coche « Processus système » pour voir aussi ceux de root.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let message = scanner.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text("\(scanner.ports.count) port\(scanner.ports.count > 1 ? "s" : "") en écoute")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func menuItems(_ port: ListeningPort) -> some View {
        Button("Ouvrir http://localhost:\(port.port)") { openInBrowser(port) }
        Button("Copier « localhost:\(port.port) »") { Finder.copy("localhost:\(port.port)") }
        if let command = port.commandLine {
            Button("Copier la ligne de commande") { Finder.copy(command) }
        }
        if let path = PortScanner.appInfo(for: port.pid).path {
            Button("Afficher l'app dans le Finder") { Finder.reveal(path) }
        }
        Divider()
        Button("Arrêter le processus…") { stopping = (port, false) }
        Button("Forcer l'arrêt…", role: .destructive) { stopping = (port, true) }
    }

    private func openInBrowser(_ port: ListeningPort) {
        if let url = URL(string: "http://localhost:\(port.port)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Icône et nom du processus (avec l'app à laquelle il appartient quand on la trouve).
private struct ProcessCell: View {
    let port: ListeningPort
    @State private var info: (icon: NSImage?, path: String?) = (nil, nil)

    var body: some View {
        HStack(spacing: 8) {
            if let icon = info.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            } else {
                Image(systemName: "gearshape").frame(width: 18)
            }
            Text(port.processName)
                .lineLimit(1)
                .help(info.path ?? port.processName)
            if let service = port.wellKnownService {
                Badge(text: service)
            }
            if let user = port.user, user != NSUserName() {
                Badge(text: user, color: .orange)
            }
        }
        .task(id: port.pid) { info = PortScanner.appInfo(for: port.pid) }
    }
}
