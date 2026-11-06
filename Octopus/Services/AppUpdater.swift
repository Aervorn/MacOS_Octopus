import Combine
import Foundation
import Observation
import Sparkle

/// Mises à jour par Sparkle, comme pour Flux et Vestora.
///
/// Le flux des versions (`appcast.xml`, à la racine du dépôt) est indiqué par `SUFeedURL` ;
/// chaque DMG est signé avec la clé EdDSA partagée avec Flux et Vestora, dont la partie publique est
/// `SUPublicEDKey` (voir scripts/make-dmg.sh). Une mise à jour mal signée est refusée.
///
/// Désactivé en Debug : un build lancé depuis Xcode ne doit pas se remplacer par la version publiée.
@MainActor
@Observable
final class AppUpdater {
    private(set) var canCheckForUpdates = false

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController?
    @ObservationIgnored private var cancellable: AnyCancellable?

    static var isEnabledByDefault: Bool {
        #if DEBUG
        false
        #else
        !OctopusApp.isRunningTests
        #endif
    }

    var isEnabled: Bool { controller != nil }

    /// `nil` : activé seulement dans l'app publiée (Release, hors tests).
    init(enabled: Bool? = nil) {
        let enabled = enabled ?? Self.isEnabledByDefault
        let controller = enabled
            ? SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
        self.controller = controller
        automaticallyChecksForUpdates = controller?.updater.automaticallyChecksForUpdates ?? false
        cancellable = controller?.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
    }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
