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
    @State private var permissions = Permissions()
    @State private var showingPermissions = false
    @AppStorage(Prefs.skipPermissionsPrompt) private var skipPermissionsPrompt = false

    var body: some Scene {
        Window("Octopus", id: Self.mainWindowID) {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environment(mole)
                .environment(session)
                .environment(updater)
                .environment(permissions)
                .task {
                    AppAppearance.apply()
                    guard !Self.isRunningTests else { return }
                    // Autorisation recommandée manquante : on le dit dès le lancement
                    if permissions.hasMissing && !skipPermissionsPrompt {
                        showingPermissions = true
                    }
                    await mole.refresh()
                }
                .sheet(isPresented: $showingPermissions) {
                    PermissionsPrompt()
                        .environment(permissions)
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

        Settings {
            SettingsView()
                .environment(updater)
                .environment(permissions)
        }
    }
}
