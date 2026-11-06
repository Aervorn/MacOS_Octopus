import AppKit
import SwiftUI

/// Homebrew : mises à jour, paquets installés, services et entretien.
struct HomebrewView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case updates = "Mises à jour"
        case installed = "Installés"
        case services = "Services"
        case maintenance = "Entretien"

        var title: String { String(localized: String.LocalizationValue(rawValue)) }
        var id: Self { self }
    }

    @Environment(TerminalSession.self) private var session
    @State private var store = HomebrewStore()
    @State private var tab: Tab = .updates

    var body: some View {
        Group {
            if store.brewPath == nil && !store.isLoading {
                notInstalled
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Picker("Section", selection: $tab) {
                            ForEach(Tab.allCases) { tab in
                                Text(label(for: tab)).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        Spacer()
                        if store.isLoading { ProgressView().controlSize(.small) }
                        if let message = store.message {
                            Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    Divider()

                    switch tab {
                    case .updates: BrewUpdatesView(store: store)
                    case .installed: BrewInstalledView(store: store)
                    case .services: BrewServicesView(store: store)
                    case .maintenance: BrewMaintenanceView(store: store)
                    }
                }
            }
        }
        .task { await store.reload() }
        // Après une commande dans le terminal (mise à jour, désinstallation, nettoyage…)
        .onChange(of: session.isRunning) { _, running in
            if !running { Task { await store.reload() } }
        }
    }

    private func label(for tab: Tab) -> String {
        switch tab {
        case .updates where !store.outdated.isEmpty: "\(tab.title) (\(store.outdated.count))"
        case .installed where !store.packages.isEmpty: "\(tab.title) (\(store.packages.count))"
        default: tab.title
        }
    }

    private var notInstalled: some View {
        ContentUnavailableView {
            Label(String(localized: "Homebrew n'est pas installé"), systemImage: "mug")
        } description: {
            Text(String(localized: "Homebrew installe les outils en ligne de commande et de nombreuses apps. L'installation officielle se fait dans le terminal et demande ton mot de passe."))
        } actions: {
            Button(String(localized: "Installer Homebrew")) {
                session.start(title: String(localized: "Installation de Homebrew"), commandLine: HomebrewStore.installCommand)
            }
            .buttonStyle(.borderedProminent)
            .disabled(session.isRunning)
        }
    }
}

// MARK: - Mises à jour

private struct BrewUpdatesView: View {
    let store: HomebrewStore
    @Environment(TerminalSession.self) private var session
    @State private var selection = Set<BrewOutdated.ID>()
    @State private var repairing: StuckCask?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.stuckCasks) { stuck in
                StuckCaskBanner(stuck: stuck) { repairing = stuck }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            }
            HStack {
                Button(String(localized: "Rechercher les mises à jour"), systemImage: "arrow.triangle.2.circlepath") {
                    Task { await store.updateIndex() }
                }
                .disabled(store.isUpdatingIndex || session.isRunning)
                if store.isUpdatingIndex {
                    ProgressView().controlSize(.small)
                    Text("brew update…").font(.caption).foregroundStyle(.secondary)
                } else if let date = store.lastIndexUpdate {
                    Text(String(localized: "Vérifié à \(date.formatted(date: .omitted, time: .shortened))"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !selection.isEmpty {
                    Button(String(localized: "Mettre à jour la sélection (\(selection.count))")) {
                        let items = store.outdated.filter { selection.contains($0.id) }
                        session.start(title: "brew upgrade", commandLine: store.upgradeCommand(items))
                    }
                    .disabled(session.isRunning)
                }
                Button(String(localized: "Tout mettre à jour")) {
                    session.start(title: "brew upgrade", commandLine: store.command(["upgrade"]))
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.outdated.isEmpty || session.isRunning)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Table(store.outdated, selection: $selection) {
                TableColumn("Paquet") { item in
                    HStack(spacing: 6) {
                        BrewIcon(kind: item.kind,
                                 appNames: store.packages.first { $0.id == item.id }?.appNames ?? [])
                        Text(item.name)
                        if item.pinned { Badge(text: String(localized: "épinglé"), color: .orange) }
                    }
                    .frame(height: 22)
                }
                .width(min: 160, ideal: 240)
                TableColumn("Type") { item in Text(LocalizedStringKey(item.kind.rawValue)).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn(String(localized: "Installée")) { item in Text(item.installed).monospacedDigit().foregroundStyle(.secondary) }
                TableColumn("Disponible") { item in Text(item.available).monospacedDigit().fontWeight(.medium) }
            }
            .confirmationDialog(
                String(localized: "Réparer la mise à jour de « \(repairing?.cask ?? "") » ?"),
                isPresented: Binding(get: { repairing != nil }, set: { if !$0 { repairing = nil } }),
                presenting: repairing
            ) { stuck in
                Button(String(localized: "Réparer et mettre à jour")) {
                    Task {
                        if await store.repair(stuck) {
                            session.start(title: "brew upgrade --cask \(stuck.cask)",
                                          commandLine: store.command(["upgrade", "--cask", stuck.cask]))
                        }
                    }
                }
                Button(String(localized: "Réparer seulement")) {
                    Task { _ = await store.repair(stuck) }
                }
            } message: { stuck in
                Text(String(localized: "L'ancienne copie de \(stuck.appName) restée dans le Caskroom part à la Corbeille. L'app utilisée, dans /Applications, n'est pas touchée."))
            }
            .overlay {
                if store.outdated.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label(String(localized: "Tout est à jour"), systemImage: "checkmark.circle")
                    } description: {
                        Text(String(localized: "D'après la dernière liste téléchargée. « Rechercher les mises à jour » la rafraîchit (brew update)."))
                    }
                }
            }
        }
    }
}

// MARK: - Installés

private struct BrewInstalledView: View {
    let store: HomebrewStore
    @Environment(TerminalSession.self) private var session
    @State private var search = ""
    @State private var kindFilter: BrewPackage.Kind?
    @State private var requestedOnly = true
    @State private var selection = Set<BrewPackage.ID>()
    @State private var sortOrder = [KeyPathComparator(\BrewPackage.name)]
    @State private var uninstalling: [BrewPackage] = []

    private var filtered: [BrewPackage] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return store.packages.filter { package in
            (kindFilter == nil || package.kind == kindFilter)
                && (!requestedOnly || package.onRequest)
                && (query.isEmpty
                    || package.name.localizedCaseInsensitiveContains(query)
                    || package.descriptionText.localizedCaseInsensitiveContains(query))
        }
        .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Type", selection: $kindFilter) {
                    Text("Tout").tag(BrewPackage.Kind?.none)
                    Text("Formules").tag(BrewPackage.Kind?.some(.formula))
                    Text("Apps").tag(BrewPackage.Kind?.some(.cask))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Toggle(String(localized: "Installés par moi"), isOn: $requestedOnly)
                    .toggleStyle(.checkbox)
                    .help(String(localized: "Masque les dépendances installées automatiquement par d'autres paquets"))
                Spacer()
                TextField("Rechercher", text: $search, prompt: Text(String(localized: "Nom ou description")))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Table(filtered, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Nom", value: \.name) { package in
                    HStack(spacing: 6) {
                        BrewIcon(kind: package.kind, appNames: package.appNames)
                        Text(package.name).fontWeight(.medium)
                        if package.outdated { Badge(text: String(localized: "mise à jour"), color: .blue) }
                        if package.pinned { Badge(text: String(localized: "épinglé"), color: .orange) }
                        if !package.onRequest { Badge(text: String(localized: "dépendance")) }
                    }
                    .frame(height: 22)
                }
                .width(min: 180, ideal: 240)
                TableColumn("Version", value: \.version) { package in
                    Text(package.version).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 100)
                TableColumn("Description", value: \.descriptionText) { package in
                    Text(package.descriptionText).foregroundStyle(.secondary).lineLimit(1).help(package.descriptionText)
                }
                .width(min: 200, ideal: 400)
                TableColumn(String(localized: "Installé le"), value: \.installedSort) { package in
                    Text(package.installedOn.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(min: 90, ideal: 110)
            }
            .contextMenu(forSelectionType: BrewPackage.ID.self) { ids in
                let targets = store.packages.filter { ids.contains($0.id) }
                if targets.count == 1, let package = targets.first {
                    if let homepage = package.homepage, let url = URL(string: homepage) {
                        Button(String(localized: "Ouvrir le site du projet")) { NSWorkspace.shared.open(url) }
                    }
                    Button(String(localized: "Infos détaillées (brew info)")) {
                        session.start(title: "brew info \(package.name)",
                                      commandLine: store.command(["info", package.kind == .cask ? "--cask" : "--formula", package.name]))
                    }
                    if package.kind == .formula {
                        Button(package.pinned ? String(localized: "Désépingler") : String(localized: "Épingler (bloquer les mises à jour)")) {
                            session.start(title: "brew pin", commandLine: store.command([package.pinned ? "unpin" : "pin", package.name]))
                        }
                    }
                    Divider()
                }
                if !targets.isEmpty {
                    Button(targets.count == 1 ? String(localized: "Désinstaller…") : String(localized: "Désinstaller les \(targets.count)…"), role: .destructive) {
                        uninstalling = targets
                    }
                }
            }
            .overlay {
                if !store.packages.isEmpty && filtered.isEmpty {
                    ContentUnavailableView(String(localized: "Aucun résultat"), systemImage: "magnifyingglass")
                }
            }
        }
        .confirmationDialog(
            uninstalling.count == 1 ? String(localized: "Désinstaller « \(uninstalling.first?.name ?? "") » ?") : String(localized: "Désinstaller \(uninstalling.count) paquets ?"),
            isPresented: Binding(get: { !uninstalling.isEmpty }, set: { if !$0 { uninstalling = [] } })
        ) {
            Button(String(localized: "Désinstaller"), role: .destructive) {
                let formulae = uninstalling.filter { $0.kind == .formula }.map(\.name)
                let casks = uninstalling.filter { $0.kind == .cask }.map(\.name)
                var parts: [String] = []
                if !formulae.isEmpty { parts.append(store.command(["uninstall", "--formula"] + formulae)) }
                if !casks.isEmpty { parts.append(store.command(["uninstall", "--cask"] + casks)) }
                session.start(title: "brew uninstall", commandLine: parts.joined(separator: " && "))
                selection.removeAll()
            }
        } message: {
            Text(String(localized: "Homebrew refusera de désinstaller un paquet dont d'autres dépendent. Les apps (casks) sont supprimées de /Applications."))
        }
    }
}

// MARK: - Services

private struct BrewServicesView: View {
    let store: HomebrewStore
    @State private var busy: String?

    var body: some View {
        Table(store.services) {
            TableColumn("Service") { service in
                HStack(spacing: 6) {
                    Circle()
                        .fill(service.isRunning ? Color.green : (service.status == "error" ? Color.red : Color.gray))
                        .frame(width: 8, height: 8)
                    Text(service.name).fontWeight(.medium)
                }
                .frame(height: 24)
            }
            .width(min: 160, ideal: 220)
            TableColumn(String(localized: "État")) { service in Text(service.statusTitle) }
                .width(min: 90, ideal: 120)
            TableColumn("Utilisateur") { service in Text(service.user ?? "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 100)
            TableColumn("Actions") { service in
                HStack {
                    if busy == service.name {
                        ProgressView().controlSize(.small)
                    } else if service.isRunning {
                        Button(String(localized: "Arrêter")) { run(service, "stop") }
                        Button(String(localized: "Redémarrer")) { run(service, "restart") }
                    } else {
                        Button(String(localized: "Démarrer")) { run(service, "start") }
                    }
                }
                .controlSize(.small)
            }
            .width(min: 160, ideal: 200)
        }
        .overlay {
            if store.services.isEmpty && !store.isLoading {
                ContentUnavailableView(String(localized: "Aucun service"), systemImage: "gearshape.2",
                                       description: Text(String(localized: "Aucun paquet installé ne propose de service (PostgreSQL, Redis, nginx…).")))
            }
        }
    }

    private func run(_ service: BrewService, _ action: String) {
        busy = service.name
        Task {
            await store.service(service, action: action)
            busy = nil
        }
    }
}

// MARK: - Entretien

private struct BrewMaintenanceView: View {
    let store: HomebrewStore
    @Environment(TerminalSession.self) private var session
    @State private var checking = false

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                DashboardCard(title: "Nettoyage", symbol: "trash") {
                    Text(String(localized: "Supprime les anciennes versions et les téléchargements en cache."))
                        .font(.callout).foregroundStyle(.secondary)
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let estimate = store.cleanupEstimate {
                        ValueRow(label: String(localized: "Espace récupérable"), value: estimate)
                    }
                    Button(String(localized: "Nettoyer (brew cleanup)")) {
                        session.start(title: "brew cleanup", commandLine: store.command(["cleanup", "--prune=all"]))
                    }
                    .disabled(session.isRunning)
                }

                DashboardCard(title: String(localized: "Dépendances inutiles"), symbol: "shippingbox") {
                    Text(String(localized: "Dépendances qui ne servent plus à aucun paquet installé."))
                        .font(.callout).foregroundStyle(.secondary)
                    if !checking {
                        if store.autoremoveCandidates.isEmpty {
                            Label("Aucune", systemImage: "checkmark.circle").foregroundStyle(.green)
                        } else {
                            Text(store.autoremoveCandidates.joined(separator: ", "))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                            Button(String(localized: "Les supprimer (brew autoremove)")) {
                                session.start(title: "brew autoremove", commandLine: store.command(["autoremove"]))
                            }
                            .disabled(session.isRunning)
                        }
                    }
                }

                DashboardCard(title: String(localized: "Diagnostic"), symbol: "stethoscope") {
                    Text(String(localized: "Vérifie l'installation de Homebrew et signale les problèmes de configuration."))
                        .font(.callout).foregroundStyle(.secondary)
                    Button(String(localized: "Lancer brew doctor")) {
                        session.start(title: "brew doctor", commandLine: store.command(["doctor"]))
                    }
                    .disabled(session.isRunning)
                    if let path = store.brewPath {
                        ValueRow(label: String(localized: "Emplacement"), value: (path as NSString).deletingLastPathComponent)
                    }
                }
            }
            .padding(20)
        }
        .task { await check() }
        .onChange(of: session.isRunning) { _, running in
            if !running { Task { await check() } }
        }
    }

    private func check() async {
        checking = true
        await store.checkMaintenance()
        checking = false
    }
}

/// Bandeau qui signale une mise à jour de cask bloquée, avec le bouton pour la réparer.
private struct StuckCaskBanner: View {
    let stuck: StuckCask
    let onRepair: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "La mise à jour de \(stuck.cask) est bloquée")).fontWeight(.semibold)
                Text(String(localized: "Une ancienne copie de \(stuck.appName), laissée par une mise à jour interrompue, empêche Homebrew de mettre l'app de côté (« It seems there is already an App at… »)."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(stuck.leftoverPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(String(localized: "Réparer…"), action: onRepair)
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Icône d'un paquet : celle de l'app pour un cask qui en installe une, sinon un symbole
/// (terminal pour une formule, paquet pour un cask sans app : police, pilote, outil…).
private struct BrewIcon: View {
    let kind: BrewPackage.Kind
    let appNames: [String]

    var body: some View {
        Group {
            if kind == .cask, let icon = AppIconCache.icon(for: appNames) {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: kind == .cask ? "shippingbox" : "terminal")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Icônes des apps installées par les casks, cherchées une fois dans /Applications et ~/Applications.
@MainActor
private enum AppIconCache {
    private static var cache: [String: NSImage?] = [:]

    static func icon(for appNames: [String]) -> NSImage? {
        guard let name = appNames.first(where: { $0.hasSuffix(".app") }) ?? appNames.first else { return nil }
        if let cached = cache[name] { return cached }
        let fileName = (name as NSString).lastPathComponent
        let candidates = ["/Applications", NSHomeDirectory() + "/Applications"]
            .map { ($0 as NSString).appendingPathComponent(fileName) }
        let icon = candidates.first { FileManager.default.fileExists(atPath: $0) }
            .map { NSWorkspace.shared.icon(forFile: $0) }
        cache[name] = icon
        return icon
    }
}
