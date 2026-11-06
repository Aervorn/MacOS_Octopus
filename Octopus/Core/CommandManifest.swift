import Foundation

/// Catalogue des commandes de Mole, lu depuis `Resources/mole-commands.json`.
///
/// Les boutons de l'interface sont générés depuis ce fichier : quand Mole ajoute une
/// sous-commande ou une option, il suffit de l'y décrire, sans toucher au code.
struct CommandManifest: Decodable {
    let schemaVersion: Int
    let testedMoleVersions: [String]
    let categories: [Category]
    let commands: [Command]

    struct Category: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
        let symbol: String
    }

    struct Command: Decodable, Identifiable, Hashable {
        let id: String
        let category: String
        let title: String
        let subtitle: String?
        let symbol: String
        let argv: [String]
        let mode: Mode
        /// Vue native (graphique) proposée à la place du terminal, si elle existe.
        let nativeView: NativeView?
        let destructive: Bool?
        let requiresAppleSilicon: Bool?
        let positional: Positional?
        let options: [Option]?
        let actions: [Action]?

        var isDestructive: Bool { destructive ?? false }
        /// Faux pour les vues qui ne pilotent pas mo (Sécurité) : pas de bascule vers le terminal.
        var hasTerminalMode: Bool { !argv.isEmpty }
    }

    enum NativeView: String, Decodable, Hashable {
        case status, analyze, history, security, ssh, ports, startup, inspector
    }

    enum Mode: String, Decodable, Hashable {
        /// Lancée dans le terminal intégré.
        case terminal
        /// Mise à jour de Mole : `brew upgrade mole` ou `mo update` selon l'installation.
        case update
    }

    struct Positional: Decodable, Hashable {
        let type: OptionType
        let label: String
        let multiple: Bool?
    }

    struct Option: Decodable, Identifiable, Hashable {
        let flag: String
        let type: OptionType
        let label: String
        let `default`: DefaultValue?
        let danger: Bool?
        let excludes: [String]?

        var id: String { flag }
        var isDangerous: Bool { danger ?? false }
    }

    /// Raccourci vers une variante de la commande (liste blanche, sous-commande…).
    struct Action: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
        let argv: [String]
    }

    enum OptionType: String, Decodable, Hashable {
        case toggle, path, number, text
    }

    /// Valeur par défaut d'une option : booléen, nombre ou texte selon son type.
    enum DefaultValue: Decodable, Hashable {
        case bool(Bool)
        case number(Double)
        case string(String)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else { self = .string(try c.decode(String.self)) }
        }

        var boolValue: Bool { if case .bool(let b) = self { b } else { false } }
        var stringValue: String {
            switch self {
            case .bool(let b): String(b)
            case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
            case .string(let s): s
            }
        }
    }

    func commands(in category: Category) -> [Command] {
        commands.filter { $0.category == category.id }
    }

    /// Manifeste embarqué dans l'app. Une erreur ici est un bug de build, pas d'exécution.
    static let bundled: CommandManifest = {
        guard let url = Bundle.main.url(forResource: "mole-commands", withExtension: "json") else {
            fatalError("mole-commands.json absent du bundle")
        }
        do {
            return try JSONDecoder().decode(CommandManifest.self, from: Data(contentsOf: url))
        } catch {
            fatalError("mole-commands.json illisible : \(error)")
        }
    }()
}

// MARK: - Construction de la ligne de commande

/// Valeurs saisies dans l'interface pour une commande.
struct CommandInput: Equatable {
    var toggles: [String: Bool] = [:]
    var values: [String: String] = [:]
    var positional: String = ""

    init() {}

    init(defaultsFor command: CommandManifest.Command) {
        for option in command.options ?? [] {
            switch option.type {
            case .toggle: toggles[option.flag] = option.default?.boolValue ?? false
            default: values[option.flag] = option.default?.stringValue ?? ""
            }
        }
    }

    /// Coche une option et décoche celles qui lui sont incompatibles (dans les deux sens).
    mutating func set(_ flag: String, _ on: Bool, in command: CommandManifest.Command) {
        toggles[flag] = on
        guard on else { return }
        for option in command.options ?? [] where option.flag != flag {
            let conflicts = (option.excludes ?? []).contains(flag)
                || (command.options?.first { $0.flag == flag }?.excludes ?? []).contains(option.flag)
            if conflicts { toggles[option.flag] = false }
        }
    }

    /// Arguments à passer à `mo`, sans le binaire.
    func arguments(for command: CommandManifest.Command) -> [String] {
        var args = command.argv
        for option in command.options ?? [] {
            switch option.type {
            case .toggle:
                if toggles[option.flag] == true { args.append(option.flag) }
            case .path, .number, .text:
                let value = (values[option.flag] ?? "").trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { args += [option.flag, value] }
            }
        }
        let positionalValue = positional.trimmingCharacters(in: .whitespaces)
        if let positionalSpec = command.positional, !positionalValue.isEmpty {
            if positionalSpec.multiple == true {
                args += positionalValue.split(whereSeparator: \.isWhitespace).map(String.init)
            } else {
                args.append(positionalValue)
            }
        }
        return args
    }

    /// Vrai si une option dangereuse est cochée (suppression définitive, confirmation automatique…).
    func hasDangerousOption(for command: CommandManifest.Command) -> Bool {
        (command.options ?? []).contains { $0.isDangerous && toggles[$0.flag] == true }
    }

    /// Vrai si la commande va réellement modifier le Mac (destructive et sans --dry-run).
    func isLiveRun(for command: CommandManifest.Command) -> Bool {
        guard command.isDestructive else { return false }
        let hasDryRun = (command.options ?? []).contains { $0.flag == "--dry-run" }
        return !hasDryRun || toggles["--dry-run"] != true
    }
}

// MARK: - Shell

enum Shell {
    /// Met un argument entre apostrophes pour zsh : `it's` devient `'it'\''s'`.
    static func quote(_ argument: String) -> String {
        if !argument.isEmpty,
           argument.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@%+,~".contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}
