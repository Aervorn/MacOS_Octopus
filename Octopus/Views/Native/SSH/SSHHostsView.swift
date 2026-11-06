import SwiftUI

/// Éditeur de ~/.ssh/config : liste des hôtes à gauche, formulaire à droite.
struct SSHHostsView: View {
    let store: SSHConfigStore
    let keys: [SSHKey]

    @State private var selection: SSHHostBlock.ID?
    @State private var deleting: SSHHostBlock?

    private var selectedBlock: SSHHostBlock? {
        store.file.blocks.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                hostList
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                editor
                    .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            if store.hasChanges || store.errorMessage != nil {
                Divider()
                saveBar
            }
        }
        .confirmationDialog(
            "Supprimer l'hôte « \(deleting?.header ?? "") » ?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { block in
            Button("Supprimer", role: .destructive) {
                store.delete(block.id)
                if selection == block.id { selection = nil }
            }
        } message: { _ in
            Text("La suppression ne sera écrite dans ~/.ssh/config qu'au moment d'enregistrer.")
        }
    }

    // MARK: - Liste

    private var hostList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.file.blocks) { block in
                    HostRow(block: block, test: block.isConcreteHost ? store.testResults[block.header] : nil)
                        .tag(block.id)
                }
                .onMove { store.move(from: $0, to: $1) }
            }
            .overlay {
                if store.file.blocks.isEmpty {
                    ContentUnavailableView("Aucun hôte", systemImage: "server.rack",
                                           description: Text("~/.ssh/config est vide ou absent."))
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button("Ajouter un hôte", systemImage: "plus") { addHost() }
                Button("Supprimer l'hôte", systemImage: "minus") { deleting = selectedBlock }
                    .disabled(selectedBlock == nil)
                Spacer()
                Text("Glisse pour réordonner").font(.caption).foregroundStyle(.tertiary)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    // MARK: - Formulaire

    @ViewBuilder private var editor: some View {
        if let block = selectedBlock {
            if block.isMatch {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Bloc « Match »").font(.title3.bold())
                    Text("Les blocs conditionnels ne se modifient pas ici. Ils sont conservés tels quels.")
                        .foregroundStyle(.secondary)
                    Text(block.rawLines.joined(separator: "\n"))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }
                .padding(20)
            } else {
                HostEditor(block: block, store: store, keys: keys)
                    .id("\(block.id)-\(store.revision)")
            }
        } else {
            ContentUnavailableView("Choisis un hôte", systemImage: "server.rack",
                                   description: Text("Ou ajoute-en un avec le bouton +."))
        }
    }

    private var saveBar: some View {
        HStack {
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label("Modifications non enregistrées", systemImage: "pencil.circle")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Annuler les modifications") { store.discardChanges() }
                .disabled(!store.hasChanges)
            Button("Enregistrer") { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!store.hasChanges)
        }
        .padding(12)
    }

    /// Enregistre puis resélectionne le même hôte (le fichier relu crée de nouveaux blocs).
    private func save() {
        let header = selectedBlock?.header
        store.save()
        if let header {
            selection = store.file.blocks.first { $0.header == header }?.id
        }
    }

    private func addHost() {
        var form = SSHHostForm()
        var name = "nouvel-hote"
        var counter = 2
        let existing = Set(store.file.blocks.map(\.header))
        while existing.contains(name) {
            name = "nouvel-hote-\(counter)"
            counter += 1
        }
        form.host = name
        selection = store.addHost(form)
    }
}

/// Ligne de la liste : alias, destination, résultat du dernier test.
private struct HostRow: View {
    let block: SSHHostBlock
    let test: SSHConfigStore.ConnectionTest?

    private var symbol: String {
        if block.isMatch { return "line.3.horizontal.decrease.circle" }
        if block.isConcreteHost { return "server.rack" }
        if block.isSharedOptions { return "square.stack.3d.up" }
        return "asterisk.circle"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.isMatch ? "Match \(block.header)" : block.header)
                    .lineLimit(1)
                    .truncationMode(.tail)
                let destination = [block.value(of: "User"), block.value(of: "HostName")]
                    .compactMap { $0 }.joined(separator: "@")
                if block.isSharedOptions {
                    Text("Options communes à \(block.patterns.count) hôtes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !block.isConcreteHost && !block.isMatch {
                    Text("Options par défaut")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !destination.isEmpty {
                    Text(destination + (block.value(of: "Port").map { ":\($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let test {
                Circle()
                    .fill(test.isSuccess ? Color.green
                          : (test == .needsAgentApproval ? Color.blue
                             : (test == .authenticationFailed ? Color.orange : Color.red)))
                    .frame(width: 8, height: 8)
                    .help(test.label)
            }
            if block.edited != nil {
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Formulaire d'un hôte ; chaque changement est reporté dans le fichier en mémoire.
private struct HostEditor: View {
    let block: SSHHostBlock
    let store: SSHConfigStore
    let keys: [SSHKey]

    @Environment(TerminalSession.self) private var session
    @State private var form: SSHHostForm

    init(block: SSHHostBlock, store: SSHConfigStore, keys: [SSHKey]) {
        self.block = block
        self.store = store
        self.keys = keys
        _form = State(initialValue: block.form)
    }

    /// Chemins des clés privées, écrits comme dans ssh_config (~/.ssh/…).
    private var keyChoices: [String] {
        keys.compactMap(\.privatePath).map { path in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        }
    }

    /// Options venant d'autres blocs qui s'appliquent aussi à cet hôte, dans l'ordre du fichier.
    /// ssh garde la première valeur rencontrée : une option déjà fixée plus haut est ignorée.
    private var inherited: [(keyword: String, value: String, source: String, ignored: Bool)] {
        guard block.isConcreteHost else { return [] }
        var seen = Set<String>()
        var result: [(keyword: String, value: String, source: String, ignored: Bool)] = []
        for other in store.file.blocks where other.applies(to: block.header) {
            for directive in other.directives {
                let key = directive.keyword.lowercased()
                // IdentityFile et les redirections peuvent apparaître plusieurs fois : elles s'additionnent
                let cumulative = ["identityfile", "localforward", "remoteforward", "dynamicforward", "certificatefile", "sendenv"].contains(key)
                let ignored = !cumulative && seen.contains(key)
                seen.insert(key)
                if other.id != block.id {
                    result.append((directive.keyword, directive.value, other.header, ignored))
                }
            }
        }
        return result
    }

    private var keysWithPublicPart: [SSHKey] { keys.filter { $0.publicPath != nil } }

    var body: some View {
        // Pas de Form « grouped » : sur macOS elle limite la largeur et centre le contenu.
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if block.isSharedOptions || (!block.isConcreteHost && !block.isMatch) {
                    Text(block.isSharedOptions
                         ? "Ces options s'appliquent à : \(block.patterns.joined(separator: ", ")). Pour chaque hôte, une option déjà fixée dans un bloc placé plus haut l'emporte."
                         : "Ces options s'appliquent à tous les hôtes qui correspondent au motif, sauf si elles sont fixées dans un bloc placé plus haut.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                EditorSection(title: block.isConcreteHost ? "Hôte" : "Motif") {
                    FieldRow(block.isConcreteHost ? "Alias (Host)" : "Hôtes concernés (Host)") {
                        TextField("", text: $form.host, prompt: Text("homelab, github.com, *.lan…"))
                    }
                    FieldRow("Adresse (HostName)") {
                        TextField("", text: $form.hostName, prompt: Text("192.168.1.10 ou serveur.exemple.fr"))
                    }
                    FieldRow("Utilisateur (User)") {
                        TextField("", text: $form.user, prompt: Text(NSUserName()))
                    }
                    FieldRow("Port") {
                        TextField("", text: $form.port, prompt: Text("22"))
                            .frame(maxWidth: 120)
                    }
                    FieldRow("Rebond (ProxyJump)") {
                        TextField("", text: $form.proxyJump, prompt: Text("bastion"))
                    }
                }

                EditorSection(title: "Clé") {
                    FieldRow("IdentityFile") {
                        HStack {
                            TextField("", text: $form.identityFile, prompt: Text("~/.ssh/id_ed25519"))
                            Menu("Choisir") {
                                Button("Aucune") { form.identityFile = "" }
                                Divider()
                                ForEach(keyChoices, id: \.self) { path in
                                    Button(path) { form.identityFile = path }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    Toggle("N'essayer que cette clé (IdentitiesOnly)", isOn: $form.identitiesOnly)
                    Toggle("Ajouter la clé à l'agent à la connexion (AddKeysToAgent)", isOn: $form.addKeysToAgent)
                    Toggle("Phrase de passe dans le trousseau macOS (UseKeychain)", isOn: $form.useKeychain)
                }

                EditorSection(title: "Autres options",
                              footer: "Une option par ligne, par exemple « ServerAliveInterval 60 ». Conservées telles quelles.") {
                    TextEditor(text: $form.otherLines)
                        .font(.callout.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 80)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }

                if !inherited.isEmpty {
                    EditorSection(title: "Options héritées",
                                  footer: "Définies dans d'autres blocs qui s'appliquent aussi à cet hôte.") {
                        ForEach(Array(inherited.enumerated()), id: \.offset) { _, option in
                            HStack(alignment: .firstTextBaseline) {
                                Text("\(option.keyword) \(option.value)")
                                    .font(.callout.monospaced())
                                    .strikethrough(option.ignored)
                                    .foregroundStyle(option.ignored ? .tertiary : .primary)
                                    .textSelection(.enabled)
                                Spacer()
                                Text(option.ignored ? "remplacée · \(option.source)" : option.source)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }

                if block.isConcreteHost && form.host.rangeOfCharacter(from: CharacterSet(charactersIn: "*?! ")) == nil {
                    EditorSection(title: "Connexion") {
                        testRow
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: form) { _, newForm in
            store.update(block.id, with: newForm)
        }
    }

    private var alias: String { form.host.trimmingCharacters(in: .whitespaces) }

    @ViewBuilder private var testRow: some View {
        HStack {
            Button("Tester la connexion") {
                Task { await store.test(alias: alias) }
            }
            .disabled(store.hasChanges || alias.isEmpty || store.testing.contains(alias))
            Button("Dans le terminal") {
                session.start(title: "ssh \(alias)", commandLine: SSHConfigStore.interactiveTestCommand(alias: alias))
            }
            .help("Connexion interactive : affiche les questions (mot de passe, clé d'hôte) et les erreurs de ssh")
            .disabled(store.hasChanges || alias.isEmpty || session.isRunning)
            Menu("Envoyer une clé") {
                ForEach(keysWithPublicPart) { key in
                    Button(key.name) {
                        session.start(title: "ssh-copy-id \(alias)",
                                      commandLine: SSHConfigStore.copyKeyCommand(publicKey: key.publicPath!, destination: alias))
                    }
                }
            }
            .fixedSize()
            .help("Ajoute la clé publique au ~/.ssh/authorized_keys de l'hôte (mot de passe demandé une fois)")
            .disabled(store.hasChanges || alias.isEmpty || session.isRunning || keysWithPublicPart.isEmpty)
            if store.testing.contains(alias) {
                ProgressView().controlSize(.small)
            }
        }
        if !store.testing.contains(alias), let result = store.testResults[alias] {
            Label(result.label, systemImage: result.isSuccess ? "checkmark.circle.fill"
                  : (result == .needsAgentApproval ? "touchid" : "xmark.circle.fill"))
                .foregroundStyle(result.isSuccess ? Color.green
                                 : (result == .needsAgentApproval ? Color.blue : Color.orange))
            if result == .needsAgentApproval {
                Text("Le serveur répond. 1Password demande de valider chaque connexion (Touch ID), ce qu'un test sans interaction ne peut pas faire : « Dans le terminal » le permet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if result == .authenticationFailed {
                Text("Le test se fait sans mot de passe ni question : la clé doit être dans l'agent SSH, ou sans phrase de passe. « Dans le terminal » montre ce qui bloque.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if store.hasChanges {
            Text("Enregistre d'abord : le test utilise le fichier sur le disque.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Section de formulaire sur toute la largeur : titre, contenu sur fond arrondi, note.
private struct EditorSection<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Ligne « libellé — champ », libellés alignés en colonne.
private struct FieldRow<Field: View>: View {
    let label: String
    let field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: 190, alignment: .leading)
            field
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
