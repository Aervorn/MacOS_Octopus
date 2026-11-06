import AppKit
import SwiftUI

/// Réglages d'Octopus (⌘,) : apparence, langue, mises à jour et autorisations.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("Général", systemImage: "gearshape") }
            Form {
                PermissionsSection()
            }
            .formStyle(.grouped)
            .frame(width: 520, height: 360)
            .tabItem { Label("Autorisations", systemImage: "lock.shield") }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppUpdater.self) private var updater
    @AppStorage(Prefs.appearance) private var appearance = AppAppearance.system
    @State private var language = AppLanguage.current
    @State private var languageChanged = false

    var body: some View {
        @Bindable var updater = updater
        Form {
            Section("Général") {
                Picker("Apparence", selection: $appearance) {
                    Text("Automatique").tag(AppAppearance.system)
                    Text("Clair").tag(AppAppearance.light)
                    Text("Sombre").tag(AppAppearance.dark)
                }
                Picker("Langue", selection: $language) {
                    Text("Langue du système").tag(AppLanguage.system)
                    Text(verbatim: "Français").tag("fr")
                    Text(verbatim: "English").tag("en")
                }
                if languageChanged {
                    HStack {
                        Text("La nouvelle langue s'appliquera au prochain lancement.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Relancer Octopus") { AppLanguage.relaunch() }
                    }
                }
            }

            Section("Mises à jour d'Octopus") {
                if updater.isEnabled {
                    Toggle("Rechercher automatiquement les mises à jour", isOn: $updater.automaticallyChecksForUpdates)
                    HStack {
                        if let date = updater.lastCheck {
                            Text("Dernière recherche : \(date.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rechercher maintenant") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                } else {
                    Text("Désactivées dans les versions de développement.")
                        .foregroundStyle(.secondary)
                }
                Text("Version \(updater.currentVersion)")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: languageChanged ? 380 : 340)
        .onChange(of: appearance) { _, value in AppAppearance.apply(value) }
        .onChange(of: language) { _, value in
            AppLanguage.set(value)
            languageChanged = true
        }
    }
}

/// État des autorisations, avec un bouton vers le bon panneau de Réglages Système.
struct PermissionsSection: View {
    @Environment(Permissions.self) private var permissions

    var body: some View {
        Section {
            PermissionRow(
                title: "Accès complet au disque",
                detail: "Recommandé : sans lui, Mole ne peut ni nettoyer ni analyser les dossiers protégés (Mail, Messages, Safari, conteneurs d'apps), et certaines analyses restent partielles.",
                status: permissions.fullDiskAccess,
                url: Permissions.fullDiskAccessURL
            )
            PermissionRow(
                title: "Gestion des apps",
                detail: "Nécessaire pour désinstaller, alléger ou mettre à jour d'autres apps (Mole, Homebrew). macOS le demande à la première utilisation ; son état ne peut pas être vérifié à l'avance.",
                status: .unknown,
                url: Permissions.appManagementURL
            )
        } header: {
            Text("Confidentialité et sécurité")
        } footer: {
            HStack {
                Text("Si Octopus n'apparaît pas dans la liste, ajoute-le avec le bouton +.")
                Spacer()
                Button("Afficher Octopus dans le Finder") { Permissions.revealApp() }
                    .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let status: Permissions.Status
    let url: URL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Text(statusText).font(.caption).foregroundStyle(color)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(status == .granted ? "Réglages…" : "Autoriser…") { Permissions.open(url) }
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .missing: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var color: Color {
        switch status {
        case .granted: .green
        case .missing: .orange
        case .unknown: .secondary
        }
    }

    private var statusText: LocalizedStringKey {
        switch status {
        case .granted: "Accordé"
        case .missing: "Non accordé"
        case .unknown: "Non vérifiable"
        }
    }
}

/// Fenêtre affichée au lancement quand une autorisation recommandée manque.
struct PermissionsPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Permissions.self) private var permissions
    @AppStorage(Prefs.skipPermissionsPrompt) private var skip = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("Autorisations recommandées").font(.title2.bold())
                    Text("Pour qu'Octopus et Mole puissent faire tout leur travail.")
                        .foregroundStyle(.secondary)
                }
            }
            Form { PermissionsSection() }
                .formStyle(.grouped)
                .frame(height: 260)
            HStack {
                Toggle("Ne plus afficher au lancement", isOn: $skip)
                    .toggleStyle(.checkbox)
                Spacer()
                Button(permissions.hasMissing ? "Plus tard" : "Terminé") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Tu retrouveras ces réglages dans Octopus › Réglages › Autorisations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 560)
    }
}
