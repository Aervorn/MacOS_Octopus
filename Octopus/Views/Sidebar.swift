import SwiftUI

extension CommandManifest.Category {
    /// Couleur de la section, déclarée dans mole-commands.json.
    var tint: Color {
        switch color {
        case "green": .green
        case "blue": .blue
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "indigo": .indigo
        default: .gray
        }
    }
}

/// Barre latérale : l'accueil, puis une carte par section, titre et contour à sa couleur.
struct Sidebar: View {
    let manifest: CommandManifest
    @Binding var selection: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SidebarRow(title: String(localized: "Accueil"), symbol: "house.fill", tint: .accentColor,
                           isSelected: selection == ContentView.homeID) {
                    selection = ContentView.homeID
                }
                .padding(.horizontal, 6)

                ForEach(manifest.categories) { category in
                    let commands = manifest.commands(in: category)
                    if !commands.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(category.title, systemImage: category.symbol)
                                .font(.caption.weight(.bold))
                                .textCase(.uppercase)
                                .foregroundStyle(category.tint)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                            ForEach(commands) { command in
                                SidebarRow(title: command.title, symbol: command.symbol, tint: category.tint,
                                           isSelected: selection == command.id) {
                                    selection = command.id
                                }
                            }
                        }
                        .padding(6)
                        .background(category.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(category.tint.opacity(0.45), lineWidth: 1)
                        )
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

/// Une entrée de la barre latérale ; sélectionnée, elle prend la couleur de sa section.
struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label {
                Text(LocalizedStringKey(title))
                    .lineLimit(1)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(isSelected ? Color.white : tint)
                    .frame(width: 20)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? tint : (isHovering ? tint.opacity(0.12) : Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// En-tête commun à toutes les vues d'outil : icône sur pastille à la couleur de la section,
/// titre et description.
struct ToolHeader: View {
    let command: CommandManifest.Command
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: command.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(command.title))
                    .font(.title2.bold())
                    .foregroundStyle(tint)
                if let subtitle = command.subtitle {
                    Text(LocalizedStringKey(subtitle))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
