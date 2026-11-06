import AppKit
import SwiftUI

/// Carte du tableau de bord : titre avec icône, puis contenu libre.
struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Ligne « libellé ……… valeur ».
struct ValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Grande valeur mise en avant (pourcentage, score…).
struct BigValue: View {
    let value: String
    var caption: String? = nil
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Barre de remplissage colorée selon le niveau (vert, orange, rouge).
struct LevelBar: View {
    /// Entre 0 et 1.
    let fraction: Double

    var body: some View {
        ProgressView(value: min(max(fraction, 0), 1))
            .tint(Self.color(for: fraction))
    }

    static func color(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: .green
        case ..<0.9: .orange
        default: .red
        }
    }
}

enum Finder {
    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

/// Message d'erreur avec bouton pour réessayer.
struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)? = nil

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
            Spacer()
            if let retry {
                Button("Réessayer", action: retry)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
