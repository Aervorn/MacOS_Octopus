import SwiftUI

@main
struct OctopusApp: App {
    static let mainWindowID = "main"

    /// Vrai quand l'app sert d'hôte aux tests : ni réseau, ni Sparkle.
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()

    @State private var mole = MoleService()
    @State private var session = TerminalSession()
    @State private var updater = AppUpdater()

    var body: some Scene {
        Window("Octopus", id: Self.mainWindowID) {
            ContentView()
                .frame(minWidth: 900, minHeight: 620)
                .environment(mole)
                .environment(session)
                .environment(updater)
                .task {
                    guard !Self.isRunningTests else { return }
                    await mole.refresh()
                }
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuItem()
                Button("Rechercher les mises à jour…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Window("À propos d'Octopus", id: AboutView.windowID) {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
