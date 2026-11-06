import AppKit
import Foundation
import Observation

/// Autorisations de « Confidentialité et sécurité » utiles à Octopus.
///
/// Les commandes lancées par Octopus (mo, brew, lsof…) héritent de ses autorisations :
/// c'est donc à Octopus qu'il faut les accorder, pas au Terminal.
@MainActor
@Observable
final class Permissions {
    enum Status { case granted, missing, unknown }

    /// Accès complet au disque : Mole peut nettoyer et analyser les dossiers protégés
    /// (Mail, Messages, Safari, conteneurs d'apps…).
    private(set) var fullDiskAccess: Status = .unknown

    var hasMissing: Bool { fullDiskAccess == .missing }

    init() {
        refresh()
        // Après un passage dans Réglages Système, l'état change sans relancer l'app
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        fullDiskAccess = Self.checkFullDiskAccess()
    }

    /// Lire un fichier protégé par TCC : possible seulement avec l'accès complet au disque.
    /// Aucune modification, et rien n'est conservé de ce qui est lu.
    private static func checkFullDiskAccess() -> Status {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let probes = [
            "\(home)/Library/Application Support/com.apple.TCC/TCC.db",
            "\(home)/Library/Safari/Bookmarks.plist",
            "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        var sawProtectedFile = false
        for path in probes where FileManager.default.fileExists(atPath: path) {
            sawProtectedFile = true
            if let handle = FileHandle(forReadingAtPath: path) {
                try? handle.close()
                return .granted
            }
        }
        return sawProtectedFile ? .missing : .unknown
    }

    // MARK: - Réglages Système

    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let appManagementURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!

    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Affiche Octopus dans le Finder, pour le glisser dans la liste de Réglages Système si besoin.
    static func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
