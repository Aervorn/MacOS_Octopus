import AppKit
import SwiftUI

/// Liste des clés de ~/.ssh, avec leurs actions.
struct SSHKeysView: View {
    let store: SSHKeyStore
    /// Alias de ~/.ssh/config, proposés comme destinations pour envoyer une clé.
    var hostAliases: [String] = []

    @Environment(TerminalSession.self) private var session
    @State private var showingGenerator = false
    @State private var editingComment: SSHKey?
    @State private var newComment = ""
    @State private var trashing: SSHKey?
    @State private var copiedKey: SSHKey.ID?
    @State private var errorMessage: String?
    @State private var sending: SendTarget?
    @State private var savingAgentKey: AgentKey?
    @State private var savedFileName = ""
    @State private var copiedAgentKey: AgentKey.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(String(localized: "Nouvelle clé…"), systemImage: "plus") { showingGenerator = true }
                    .disabled(session.isRunning)
                if store.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                // Pour 1Password, l'état est affiché en haut de la vue (OnePasswordBadge)
                if !store.agentAvailable && !store.isOnePasswordAgent {
                    Label(store.isOnePasswordAgent ? String(localized: "Agent 1Password injoignable") : String(localized: "Agent SSH injoignable"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(store.isOnePasswordAgent
                              ? String(localized: "Ouvre et déverrouille 1Password, puis vérifie Réglages › Développeur › « Utiliser l'agent SSH ».")
                              : String(localized: "Aucun agent SSH ne répond : les clés ne peuvent pas y être ajoutées."))
                    if store.isOnePasswordAgent {
                        Button("Ouvrir 1Password") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.1password.1password") {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Button("Actualiser", systemImage: "arrow.clockwise") { Task { await store.reload() } }
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            if let errorMessage {
                ErrorBanner(message: errorMessage).padding(.horizontal, 14)
            }

            List {
                Section {
                    ForEach(store.keys) { key in
                        row(key)
                            .contextMenu { menuItems(key) }
                    }
                } header: {
                    if !store.agentOnlyKeys.isEmpty { Text("Dans ~/.ssh") }
                }
                if !store.agentOnlyKeys.isEmpty {
                    Section {
                        ForEach(store.agentOnlyKeys) { key in
                            agentRow(key)
                                .contextMenu { agentMenuItems(key) }
                        }
                    } header: {
                        Text(store.isOnePasswordAgent ? String(localized: "Dans l'agent 1Password") : String(localized: "Dans l'agent SSH"))
                    } footer: {
                        Text(String(localized: "Clés détenues par l'agent, sans fichier dans ~/.ssh. La clé privée ne quitte jamais l'agent."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if store.keys.isEmpty && store.agentOnlyKeys.isEmpty && !store.isLoading {
                    ContentUnavailableView {
                        Label(String(localized: "Aucune clé SSH"), systemImage: "key")
                    } description: {
                        Text(String(localized: "Crée ta première clé, Ed25519 de préférence."))
                    } actions: {
                        Button(String(localized: "Nouvelle clé…")) { showingGenerator = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showingGenerator) {
            KeyGeneratorSheet { command in
                session.start(title: "ssh-keygen", commandLine: command)
            }
        }
        .sheet(item: $sending) { target in
            SendKeySheet(name: target.name, hostAliases: hostAliases) { destination in
                send(target, to: destination)
            }
        }
        .alert(String(localized: "Enregistrer la clé publique dans ~/.ssh"), isPresented: Binding(
            get: { savingAgentKey != nil }, set: { if !$0 { savingAgentKey = nil } }
        )) {
            TextField(String(localized: "Nom du fichier"), text: $savedFileName)
            Button("Enregistrer") { saveAgentKey() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(String(localized: "Le fichier .pub pourra servir d'IdentityFile pour choisir cette clé de l'agent pour un hôte."))
        }
        .alert(String(localized: "Modifier le commentaire"), isPresented: Binding(
            get: { editingComment != nil }, set: { if !$0 { editingComment = nil } }
        )) {
            TextField("Commentaire", text: $newComment)
            Button("Modifier") {
                if let key = editingComment {
                    session.start(title: "ssh-keygen -c", commandLine: SSHKeyStore.changeCommentCommand(key, comment: newComment))
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text(String(localized: "Si la clé a une phrase de passe, elle te sera demandée dans le terminal."))
        }
        .confirmationDialog(
            String(localized: "Mettre « \(trashing?.name ?? "") » à la corbeille ?"),
            isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } }),
            presenting: trashing
        ) { key in
            Button(String(localized: "Mettre à la corbeille"), role: .destructive) {
                do {
                    try store.moveToTrash(key)
                    Task { await store.reload() }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        } message: { _ in
            Text(String(localized: "La clé privée et la clé publique partent à la Corbeille. Les serveurs qui n'acceptent que cette clé ne te laisseront plus entrer."))
        }
    }

    // MARK: - Ligne

    private func row(_ key: SSHKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: key.privatePath == nil ? "key.horizontal" : "key.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(key.name).font(.headline)
                    if let type = key.type {
                        Badge(text: [type, key.bits.map(String.init)].compactMap { $0 }.joined(separator: " "),
                              color: type == "RSA" && (key.bits ?? 0) < 3072 ? .orange : .secondary)
                    }
                    if key.isInAgent {
                        Badge(text: String(localized: "Dans l'agent"), color: .green)
                    }
                }
                if let comment = key.comment {
                    Text(comment).foregroundStyle(.secondary)
                }
                if let fingerprint = key.fingerprint {
                    Text(fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 10) {
                    switch key.hasPassphrase {
                    case true?:
                        Label(String(localized: "Phrase de passe"), systemImage: "lock.fill").foregroundStyle(.green)
                    case false?:
                        Label(String(localized: "Sans phrase de passe"), systemImage: "lock.open").foregroundStyle(.orange)
                    case nil where key.privatePath == nil:
                        Label(String(localized: "Clé publique seule"), systemImage: "questionmark.circle").foregroundStyle(.secondary)
                    case nil:
                        EmptyView()
                    }
                    if key.publicPath == nil {
                        Label(String(localized: "Clé publique absente"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    if let date = key.modified {
                        Text(String(localized: "Modifiée le \(date.formatted(date: .abbreviated, time: .omitted))"))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
            }

            Spacer()

            Button {
                if store.copyPublicKey(key) {
                    copiedKey = key.id
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        if copiedKey == key.id { copiedKey = nil }
                    }
                }
            } label: {
                Label(copiedKey == key.id ? String(localized: "Copiée") : String(localized: "Copier la clé publique"),
                      systemImage: copiedKey == key.id ? "checkmark" : "doc.on.doc")
            }
            .disabled(key.publicPath == nil)

            Menu {
                menuItems(key)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    // MARK: - Clés de l'agent

    private func agentRow(_ key: AgentKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.badge.key.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(key.name).font(.headline)
                    if let type = key.type {
                        Badge(text: [type, key.bits.map(String.init)].compactMap { $0 }.joined(separator: " "),
                              color: type == "RSA" && (key.bits ?? 0) < 3072 ? .orange : .secondary)
                    }
                    Badge(text: String(localized: "Dans l'agent"), color: .green)
                }
                Text(key.fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                store.copyPublicKey(key)
                copiedAgentKey = key.id
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if copiedAgentKey == key.id { copiedAgentKey = nil }
                }
            } label: {
                Label(copiedAgentKey == key.id ? String(localized: "Copiée") : String(localized: "Copier la clé publique"),
                      systemImage: copiedAgentKey == key.id ? "checkmark" : "doc.on.doc")
            }
            .disabled(key.publicKey.isEmpty)
            Menu {
                agentMenuItems(key)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func agentMenuItems(_ key: AgentKey) -> some View {
        Button(String(localized: "Envoyer vers un hôte…")) { sending = .agent(key) }
            .disabled(session.isRunning || key.publicKey.isEmpty)
        Button(String(localized: "Enregistrer la clé publique dans ~/.ssh…")) {
            savedFileName = key.suggestedFileName
            savingAgentKey = key
        }
        .disabled(key.publicKey.isEmpty)
    }

    private func saveAgentKey() {
        guard let key = savingAgentKey else { return }
        var name = savedFileName.trimmingCharacters(in: .whitespaces)
        if !name.hasSuffix(".pub") { name += ".pub" }
        guard !name.contains("/"), !name.hasPrefix(".") else {
            errorMessage = String(localized: "Nom de fichier invalide.")
            return
        }
        guard !FileManager.default.fileExists(atPath: SSHKeyStore.directory.appendingPathComponent(name).path) else {
            errorMessage = "~/.ssh/\(name) existe déjà."
            return
        }
        do {
            _ = try store.savePublicKey(key, fileName: name)
            errorMessage = nil
            Task { await store.reload() }
        } catch {
            errorMessage = String(localized: "Enregistrement impossible : \(error.localizedDescription)")
        }
    }

    // MARK: - Envoi vers un hôte

    private func send(_ target: SendTarget, to destination: String) {
        let path: String
        switch target {
        case .file(let key):
            path = key.publicPath ?? key.mainPath
        case .agent(let key):
            do {
                path = try SSHKeyStore.temporaryPublicKeyFile(key)
            } catch {
                errorMessage = String(localized: "Impossible de préparer la clé : \(error.localizedDescription)")
                return
            }
        }
        session.start(title: "ssh-copy-id \(destination)",
                      commandLine: SSHConfigStore.copyKeyCommand(publicKey: path, destination: destination))
    }

    @ViewBuilder
    private func menuItems(_ key: SSHKey) -> some View {
        if key.privatePath != nil {
            if key.isInAgent {
                Button(String(localized: "Retirer de l'agent")) {
                    session.start(title: "ssh-add -d", commandLine: SSHKeyStore.removeFromAgentCommand(key))
                }
            } else {
                Button(String(localized: "Ajouter à l'agent et au trousseau")) {
                    session.start(title: "ssh-add --apple-use-keychain", commandLine: SSHKeyStore.addToAgentCommand(key))
                }
            }
            Button(String(localized: "Changer la phrase de passe…")) {
                session.start(title: "ssh-keygen -p", commandLine: SSHKeyStore.changePassphraseCommand(key))
            }
            Button(String(localized: "Modifier le commentaire…")) {
                newComment = key.comment ?? ""
                editingComment = key
            }
            Divider()
        }
        if key.publicPath != nil {
            Button(String(localized: "Envoyer vers un hôte…")) { sending = .file(key) }
                .disabled(session.isRunning)
            Divider()
        }
        Button(String(localized: "Afficher dans le Finder")) { Finder.reveal(key.mainPath) }
        if let pub = key.publicPath {
            Button(String(localized: "Copier le chemin de la clé publique")) { Finder.copy(pub) }
        }
        Divider()
        Button(String(localized: "Mettre à la corbeille…"), role: .destructive) { trashing = key }
    }
}

/// Petite étiquette arrondie.
struct Badge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// Formulaire de création d'une clé : la phrase de passe est demandée ensuite dans le terminal.
private struct KeyGeneratorSheet: View {
    let onGenerate: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var type: SSHKeyStore.KeyType = .ed25519
    @State private var fileName = SSHKeyStore.KeyType.ed25519.defaultFileName
    @State private var fileNameEdited = false
    @State private var comment = SSHKeyStore.defaultComment
    @State private var addToKeychain = true

    private var trimmedName: String { fileName.trimmingCharacters(in: .whitespaces) }
    private var nameIsValid: Bool {
        !trimmedName.isEmpty && !trimmedName.contains("/") && !trimmedName.hasPrefix(".")
    }
    private var exists: Bool { SSHKeyStore.fileExists(trimmedName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Nouvelle clé SSH")).font(.title2.bold())

            Form {
                Picker("Type", selection: $type) {
                    ForEach(SSHKeyStore.KeyType.allCases) { Text($0.rawValue).tag($0) }
                }
                TextField("Fichier (~/.ssh/)", text: Binding(
                    get: { fileName },
                    set: { fileName = $0; fileNameEdited = true }
                ))
                TextField("Commentaire", text: $comment)
                Toggle(String(localized: "Ajouter à l'agent et au trousseau macOS"), isOn: $addToKeychain)
            }
            .formStyle(.grouped)

            if exists {
                Label(String(localized: "Une clé porte déjà ce nom : choisis-en un autre."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(String(localized: "La phrase de passe te sera demandée dans le terminal. Elle protège la clé si ton Mac est volé : recommandé."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "Créer")) {
                    onGenerate(SSHKeyStore.generateCommand(
                        type: type, fileName: trimmedName, comment: comment, addToKeychain: addToKeychain))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!nameIsValid || exists)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: type) { _, newType in
            if !fileNameEdited { fileName = newType.defaultFileName }
        }
    }
}

/// Clé à envoyer : un fichier de ~/.ssh ou une clé de l'agent.
private enum SendTarget: Identifiable {
    case file(SSHKey)
    case agent(AgentKey)

    var id: String {
        switch self {
        case .file(let key): "file:" + key.id
        case .agent(let key): "agent:" + key.id
        }
    }

    var name: String {
        switch self {
        case .file(let key): key.name
        case .agent(let key): key.name
        }
    }
}

/// Choix de l'hôte qui recevra la clé publique (ajoutée à son ~/.ssh/authorized_keys).
private struct SendKeySheet: View {
    let name: String
    let hostAliases: [String]
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var custom = ""
    @State private var useCustom = false

    private var destination: String {
        (useCustom || hostAliases.isEmpty ? custom : alias).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Envoyer « \(name) » vers un hôte")).font(.title2.bold())

            Form {
                if !hostAliases.isEmpty {
                    Picker("Destination", selection: $useCustom) {
                        Text(String(localized: "Un hôte de ~/.ssh/config")).tag(false)
                        Text(String(localized: "Une autre adresse")).tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if !useCustom {
                        Picker(String(localized: "Hôte"), selection: $alias) {
                            ForEach(hostAliases, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                if useCustom || hostAliases.isEmpty {
                    TextField("Adresse", text: $custom, prompt: Text("utilisateur@192.168.1.10"))
                }
            }
            .formStyle(.grouped)

            Text(String(localized: "La clé publique est ajoutée au fichier ~/.ssh/authorized_keys de l'hôte. Le mot de passe du compte distant te sera demandé une fois, dans le terminal. Pour un port autre que 22, crée plutôt l'hôte dans l'onglet Hôtes."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Envoyer") {
                    onSend(destination)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { alias = hostAliases.first ?? "" }
    }
}
