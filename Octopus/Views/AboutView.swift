import AppKit
import SwiftUI

/// Fenêtre « À propos d'Octopus », dans le même style que celles de Flux, Navloom et Vestora.
struct AboutView: View {
    static let windowID = "about"
    static let repositoryURL = URL(string: "https://github.com/Aervorn/MacOS_Octopus")!
    static let moleURL = URL(string: "https://github.com/tw93/Mole")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(short) (\(build))")
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

            Text("Une interface pour Mole, et une boîte à outils pour ton Mac : nettoyage, apps, sécurité, SSH, réseau.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            // Mole : le moteur du nettoyage, mis en avant
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "hammer.fill").foregroundStyle(.tint)
                    Text("Propulsé par Mole").fontWeight(.semibold)
                }
                Text("Outil de nettoyage et d'entretien en ligne de commande, par [tw93](https://github.com/tw93) (GPL-3.0).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link(destination: Self.moleURL) {
                    Label("Mole sur GitHub", systemImage: "arrow.up.right.square")
                }
                .font(.callout)
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 16)

            Divider().padding(.vertical, 16)

            VStack(spacing: 6) {
                Text("Créé par Aervorn, avec l'aide de Claude.")
                Text("Terminal : [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) · Mises à jour : [Sparkle](https://sparkle-project.org) (MIT)")
                Text("Vérifications de sécurité inspirées de [SilentKnight](https://eclecticlight.co/lockrattler-systhist/) (Howard Oakley).")
                Text("Octopus n'est affilié ni à Mole ni à ses auteurs : il utilise le Mole installé sur ton Mac.")
                    .padding(.top, 4)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Link(destination: Self.repositoryURL) {
                Label("Code source d'Octopus sur GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            .font(.callout)
            .padding(.top, 14)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .padding(.top, 12)
        .frame(width: 400)
    }
}

/// Entrée « À propos d'Octopus » du menu de l'application.
struct AboutMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("À propos d'Octopus") { openWindow(id: AboutView.windowID) }
    }
}
