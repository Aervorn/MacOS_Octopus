import AppKit
import SwiftUI

/// Réglages cachés de macOS (façon OnyX) et petites opérations de maintenance.
struct TweaksView: View {
    @State private var store = TweaksStore()
    @State private var running: TweaksStore.Maintenance?

    private let columns = [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(String(localized: "Chaque réglage s'applique immédiatement ; le Finder, le Dock ou le serveur des captures sont relancés si besoin. Clic droit sur un réglage pour revenir à la valeur de macOS."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if let message = store.message {
                    Label(message, systemImage: "checkmark.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.groups) { group in
                        DashboardCard(title: group.title, symbol: group.symbol) {
                            ForEach(group.tweaks) { tweak in
                                TweakRow(tweak: tweak, store: store)
                                    .contextMenu {
                                        Button(String(localized: "Revenir au réglage par défaut")) {
                                            Task { await store.reset(tweak) }
                                        }
                                    }
                            }
                        }
                    }
                    maintenanceCard
                }
            }
            .padding(20)
        }
        .task { store.reload() }
    }

    private var maintenanceCard: some View {
        DashboardCard(title: String(localized: "Maintenance"), symbol: "wrench.and.screwdriver") {
            ForEach(TweaksStore.Maintenance.allCases) { action in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: action.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(action.title).fontWeight(.medium)
                            if action.needsAdmin {
                                Image(systemName: "touchid").font(.caption).foregroundStyle(.secondary)
                                    .help(String(localized: "Demande les droits administrateur"))
                            }
                        }
                        Text(action.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if running == action {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Lancer") {
                            running = action
                            Task {
                                await store.run(action)
                                running = nil
                            }
                        }
                        .disabled(running != nil)
                    }
                }
            }
        }
    }
}

/// Une ligne de réglage : case, menu, curseur ou dossier selon le type.
private struct TweakRow: View {
    let tweak: Tweak
    let store: TweaksStore

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            control
            if let detail = tweak.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, isToggle ? 20 : 0)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isToggle: Bool { if case .toggle = tweak.kind { true } else { false } }

    @ViewBuilder private var control: some View {
        switch tweak.kind {
        case .toggle:
            Toggle(tweak.title, isOn: Binding(
                get: { store.bool(tweak) },
                set: { value in Task { await store.set(tweak, bool: value) } }
            ))
            .toggleStyle(.checkbox)

        case .choice(let options, _):
            Picker(tweak.title, selection: Binding(
                get: { store.string(tweak) },
                set: { value in Task { await store.set(tweak, string: value) } }
            )) {
                ForEach(options.indices, id: \.self) { index in
                    Text(options[index].label).tag(options[index].value)
                }
            }
            .fixedSize()

        case .number(_, let range, let step, let unit):
            NumberTweak(title: tweak.title, value: store.number(tweak), range: range, step: step, unit: unit) { value in
                Task { await store.set(tweak, number: value) }
            }

        case .folder:
            HStack {
                Text(tweak.title)
                Spacer()
                Text(shortPath(store.string(tweak)))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button(String(localized: "Choisir…")) { chooseFolder() }
            }
        }
    }

    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: store.string(tweak))
        if panel.runModal() == .OK, let url = panel.url {
            Task { await store.set(tweak, string: url.path) }
        }
    }
}

/// Curseur qui n'écrit la valeur qu'au relâchement (sinon le Dock serait relancé à chaque pas).
///
/// Une valeur hors de la plage du curseur a été fixée par une autre app : DockDoor, par exemple,
/// règle le délai d'apparition du Dock à 1000 s pour le faire disparaître. Elle est alors
/// affichée telle quelle, et le curseur n'apparaît que si on choisit de la modifier.
private struct NumberTweak: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let unit: String
    let onCommit: (Double) -> Void

    @State private var draft: Double?
    @State private var overriding = false

    private var isOutOfRange: Bool { !range.contains(value) }

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
            Spacer()
            if isOutOfRange && !overriding {
                Text("\(value.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .help(String(localized: "Valeur fixée par une autre app (DockDoor, par exemple, masque ainsi le Dock). La modifier peut perturber cette app."))
                Button(String(localized: "Modifier…")) { overriding = true }
                    .controlSize(.small)
            } else {
                Slider(value: Binding(get: { draft ?? min(max(value, range.lowerBound), range.upperBound) },
                                      set: { draft = $0 }),
                       in: range, step: step,
                       onEditingChanged: { editing in
                           if !editing, let draft {
                               onCommit(draft)
                               self.draft = nil
                               overriding = false
                           }
                       })
                .frame(width: 140)
                Text("\((draft ?? min(max(value, range.lowerBound), range.upperBound)).formatted(.number.precision(.fractionLength(1)))) \(unit)")
                    .monospacedDigit()
                    .fixedSize()
                    .frame(minWidth: 48, alignment: .trailing)
            }
        }
    }
}
