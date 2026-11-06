import AppKit
import SwiftUI

/// Fenêtre « À propos d'Octopus », dans le même style que celles de Flux et Vestora.
struct AboutView: View {
    static let windowID = "about"
    static let repositoryURL = URL(string: "https://github.com/Aervorn/MacOS_Octopus")!
    static let moleURL = URL(string: "https://github.com/tw93/Mole")!
    static let swiftTermURL = URL(string: "https://github.com/migueldeicaza/SwiftTerm")!
    static let sparkleURL = URL(string: "https://sparkle-project.org")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .padding(.top, 8)

            Text("Octopus")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 6)
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)

            Text("Une interface graphique pour Mole, l'outil de nettoyage et d'entretien de macOS en ligne de commande.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Divider().padding(.vertical, 16)

            VStack(spacing: 6) {
                Text("Créé par Aervorn, avec l'aide de Claude.")
                HStack(spacing: 4) {
                    Text("Moteur :")
                    Link("Mole", destination: Self.moleURL)
                    Text("par tw93")
                }
                HStack(spacing: 4) {
                    Text("Terminal :")
                    Link("SwiftTerm", destination: Self.swiftTermURL)
                    Text("· Mises à jour :")
                    Link("Sparkle", destination: Self.sparkleURL)
                }
                Text("Octopus n'est pas affilié à Mole ni à son auteur.")
                    .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Link(destination: Self.repositoryURL) {
                Label("Code source sur GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .font(.callout)
            .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 12)
        .frame(width: 360)
    }
}

/// Entrée « À propos d'Octopus » du menu de l'application.
struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("À propos d'Octopus") { openWindow(id: AboutView.windowID) }
    }
}
