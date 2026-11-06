import AppKit
import Observation
import UniformTypeIdentifiers

/// Un type de fichier (ou de lien) et l'app qui l'ouvre par défaut.
struct OpenWithEntry: Identifiable, Equatable {
    enum Target: Equatable {
        case type(UTType)
        /// Schéma d'URL : « http » (navigateur), « mailto » (messagerie).
        case scheme(String)
    }

    let id: String
    let title: String
    let extensions: [String]
    let target: Target
    let family: String
    var defaultApp: URL?
    var candidates: [URL] = []

    var icon: NSImage {
        switch target {
        case .type(let type): NSWorkspace.shared.icon(for: type)
        case .scheme: NSWorkspace.shared.icon(for: .url)
        }
    }

    var extensionsText: String {
        switch target {
        case .type: extensions.map { "." + $0 }.joined(separator: " ")
        case .scheme(let scheme): scheme == "http" ? "http, https" : scheme
        }
    }
}

/// Lit et modifie les apps par défaut (Launch Services).
@MainActor
@Observable
final class DefaultAppsStore {
    private(set) var entries: [OpenWithEntry] = []
    private(set) var message: String?

    /// Extensions ajoutées par l'utilisateur, gardées d'une session à l'autre.
    private static let customKey = "DefaultApps.customExtensions"
    private var customExtensions: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.customKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.customKey) }
    }

    static let families: [(title: String, extensions: [String])] = [
        (String(localized: "Documents"), ["pdf", "txt", "md", "rtf", "docx", "xlsx", "pptx", "odt", "csv", "epub"]),
        (String(localized: "Images"), ["jpg", "png", "heic", "gif", "webp", "svg", "tiff", "bmp", "psd"]),
        (String(localized: "Audio"), ["mp3", "m4a", "flac", "wav", "aac", "ogg"]),
        (String(localized: "Vidéo"), ["mp4", "mov", "mkv", "avi", "webm", "m4v"]),
        (String(localized: "Code et configuration"), ["swift", "py", "js", "ts", "json", "html", "css", "sh", "zsh", "yaml",
                                   "toml", "xml", "plist", "log", "sql", "c", "go", "rs", "php", "rb", "conf", "env"]),
        (String(localized: "Archives et images disque"), ["zip", "7z", "rar", "gz", "tgz", "tar", "dmg", "iso"]),
    ]

    static let familyOrder = [String(localized: "Liens")] + families.map(\.title) + [String(localized: "Ajoutés")]

    func reload() {
        var result: [OpenWithEntry] = [
            makeScheme("http", title: String(localized: "Navigateur web")),
            makeScheme("mailto", title: String(localized: "Messagerie")),
        ]
        var seen = Set<String>()
        for family in Self.families {
            for ext in family.extensions {
                if let entry = makeType(ext, family: family.title), seen.insert(entry.id).inserted {
                    result.append(entry)
                }
            }
        }
        for ext in customExtensions {
            if let entry = makeType(ext, family: String(localized: "Ajoutés")), seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        entries = result
    }

    /// Ajoute une extension à la liste (« toml », « .heif »…). Renvoie faux si elle est inconnue.
    @discardableResult
    func addExtension(_ text: String) -> Bool {
        let ext = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard !ext.isEmpty, UTType(filenameExtension: ext) != nil else { return false }
        if let existing = entries.first(where: { $0.extensions.contains(ext) }) {
            message = String(localized: ".\(ext) est déjà dans la liste (\(existing.title)).")
            return true
        }
        customExtensions.append(ext)
        reload()
        return true
    }

    func removeCustom(_ entry: OpenWithEntry) {
        customExtensions.removeAll { entry.extensions.contains($0) }
        reload()
    }

    /// Change l'app par défaut. Pour un lien (navigateur, messagerie), macOS demande confirmation.
    func setDefault(_ app: URL, for targets: [OpenWithEntry]) async {
        var failures: [String] = []
        for entry in targets {
            do {
                switch entry.target {
                case .type(let type):
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
                case .scheme(let scheme):
                    try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
                }
            } catch {
                failures.append(entry.title)
            }
        }
        let name = app.deletingPathExtension().lastPathComponent
        if failures.isEmpty {
            message = targets.count == 1
                ? String(localized: "« \(targets[0].title) » s'ouvre maintenant avec \(name).")
                : String(localized: "\(targets.count) types s'ouvrent maintenant avec \(name).")
        } else {
            message = String(localized: "Refusé pour : \(failures.joined(separator: ", ")).")
        }
        reload()
    }

    // MARK: - Construction

    private func makeType(_ ext: String, family: String) -> OpenWithEntry? {
        guard let type = UTType(filenameExtension: ext) else { return nil }
        let extensions = type.tags[.filenameExtension] ?? [ext]
        // Type « dynamique » : aucune app installée ne le déclare, macOS ne lui donne pas de nom
        let title = type.isDynamic ? ext.uppercased() : (type.localizedDescription ?? ext.uppercased())
        return OpenWithEntry(
            id: type.identifier,
            title: title,
            extensions: extensions.contains(ext) ? [ext] + extensions.filter { $0 != ext } : extensions,
            target: .type(type),
            family: family,
            defaultApp: NSWorkspace.shared.urlForApplication(toOpen: type),
            candidates: Self.sorted(NSWorkspace.shared.urlsForApplications(toOpen: type))
        )
    }

    private func makeScheme(_ scheme: String, title: String) -> OpenWithEntry {
        let sample = URL(string: scheme == "mailto" ? "mailto:test@example.com" : "\(scheme)://example.com")!
        return OpenWithEntry(
            id: "scheme:\(scheme)",
            title: title,
            extensions: [],
            target: .scheme(scheme),
            family: String(localized: "Liens"),
            defaultApp: NSWorkspace.shared.urlForApplication(toOpen: sample),
            candidates: Self.sorted(NSWorkspace.shared.urlsForApplications(toOpen: sample))
        )
    }

    /// Apps de /Applications d'abord, sans doublons, par nom.
    private static func sorted(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { lhs, rhs in
                let l = lhs.path.hasPrefix("/Applications") || lhs.path.hasPrefix("/System/Applications")
                let r = rhs.path.hasPrefix("/Applications") || rhs.path.hasPrefix("/System/Applications")
                if l != r { return l }
                return lhs.deletingPathExtension().lastPathComponent
                    .localizedStandardCompare(rhs.deletingPathExtension().lastPathComponent) == .orderedAscending
            }
    }
}
