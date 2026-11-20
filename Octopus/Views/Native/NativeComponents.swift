import AppKit
import SwiftUI

/// Carte du tableau de bord : titre avec icône, puis contenu libre.
struct DashboardCard<Content: View>: View {
    let title: String
    let symbol: String
    /// Contenu centré dans un cadre gris clair, comme les `StatCard` (accueil).
    var centered = false
    /// Cadre gris clair sans centrer le contenu (cartes pleines de lignes « libellé … valeur »).
    var outlined = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 10) {
            Label(LocalizedStringKey(title), systemImage: symbol)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .top : .topLeading)
        .background(.quaternary.opacity(hasBorder ? 0.25 : 0.45), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if hasBorder {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
            }
        }
    }

    private var hasBorder: Bool { centered || outlined }
}

/// Ligne « libellé ……… valeur ».
struct ValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(LocalizedStringKey(label)).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.callout)
    }
}

/// Carte de chiffre clé : icône, grande valeur et libellé centrés, dans un cadre gris clair.
struct StatCard: View {
    let symbol: String
    let value: String
    let caption: String
    var color: Color = .primary
    /// Explication affichée au survol, signalée par une petite icône ⓘ.
    var info: String? = nil

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 4) {
                Text(LocalizedStringKey(caption))
                if info != nil {
                    Image(systemName: "info.circle")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
        .help(info ?? "")
    }
}

/// Grande valeur mise en avant (pourcentage, score…).
struct BigValue: View {
    let value: String
    var caption: String? = nil
    var color: Color = .primary
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
            if let caption {
                Text(LocalizedStringKey(caption)).font(.caption).foregroundStyle(.secondary)
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
                Button(String(localized: "Réessayer"), action: retry)
            }
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
