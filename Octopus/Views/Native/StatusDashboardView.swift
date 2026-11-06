import Charts
import SwiftUI

/// Tableau de bord en direct alimenté par `mo status --watch`.
struct StatusDashboardView: View {
    let executable: String

    @State private var store = StatusStore()

    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let message = store.errorMessage {
                    ErrorBanner(message: message) {
                        store.stop()
                        store.start(executable: executable)
                    }
                }
                if let status = store.latest {
                    header(status)
                    LazyVGrid(columns: columns, spacing: 14) {
                        cpuCard(status)
                        memoryCard(status)
                        disksCard(status)
                        if let battery = status.batteries?.first {
                            batteryCard(battery, thermal: status.thermal)
                        }
                        networkCard(status)
                        processesCard(status)
                    }
                } else if store.errorMessage == nil {
                    ProgressView("Lecture de l'état du Mac…")
                        .frame(maxWidth: .infinity, minHeight: 300)
                }
            }
            .padding(20)
        }
        .task { store.start(executable: executable) }
        .onDisappear { store.stop() }
    }

    // MARK: - En-tête

    private func header(_ status: MoleStatus) -> some View {
        HStack(alignment: .center, spacing: 18) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: Double(status.healthScore ?? 0) / 100)
                    .stroke(healthColor(status.healthScore), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(Fmt.integer(status.healthScore))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
            }
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 3) {
                Text(status.healthScoreMsg ?? "Santé")
                    .font(.title2.bold())
                Text([status.hardware?.model, status.hardware?.cpuModel, status.hardware?.totalRam]
                    .compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text([status.hardware?.osVersion, status.uptime.map { "allumé depuis \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let trash = status.trashSize, trash > 0 {
                VStack(alignment: .trailing) {
                    Text("Corbeille").font(.caption).foregroundStyle(.secondary)
                    Text(Fmt.bytes(trash)).font(.title3.monospacedDigit())
                }
            }
        }
    }

    private func healthColor(_ score: Int?) -> Color {
        switch score ?? 0 {
        case 80...: .green
        case 50..<80: .orange
        default: .red
        }
    }

    // MARK: - Cartes

    private func cpuCard(_ status: MoleStatus) -> some View {
        DashboardCard(title: "Processeur", symbol: "cpu") {
            HStack(alignment: .firstTextBaseline) {
                BigValue(value: Fmt.percent(status.cpu?.usage),
                         caption: coreCaption(status.cpu))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Charge").font(.caption).foregroundStyle(.secondary)
                    Text([status.cpu?.load1, status.cpu?.load5, status.cpu?.load15]
                        .map { Fmt.number($0, decimals: 2) }.joined(separator: " · "))
                        .font(.callout.monospacedDigit())
                }
            }
            historyChart(\.cpu, color: .blue)
            if let cores = status.cpu?.perCore, !cores.isEmpty {
                Chart(Array(cores.enumerated()), id: \.offset) { index, usage in
                    BarMark(x: .value("Cœur", "\(index + 1)"), y: .value("Utilisation", usage))
                        .foregroundStyle(LevelBar.color(for: usage / 100))
                }
                .chartYScale(domain: 0...100)
                .chartYAxis(.hidden)
                .chartXAxis(.hidden)
                .frame(height: 36)
            }
        }
    }

    private func coreCaption(_ cpu: MoleStatus.CPU?) -> String? {
        guard let cpu, let count = cpu.coreCount else { return nil }
        if let p = cpu.pCoreCount, let e = cpu.eCoreCount {
            return "\(count) cœurs (\(p) performance, \(e) efficacité)"
        }
        return "\(count) cœurs"
    }

    private func memoryCard(_ status: MoleStatus) -> some View {
        DashboardCard(title: "Mémoire", symbol: "memorychip") {
            let memory = status.memory
            BigValue(value: Fmt.percent(memory?.usedPercent),
                     caption: "\(Fmt.bytes(memory?.used)) sur \(Fmt.bytes(memory?.total))")
            historyChart(\.memory, color: .purple)
            ValueRow(label: "Disponible", value: Fmt.bytes(memory?.available))
            ValueRow(label: "En cache", value: Fmt.bytes(memory?.cached))
            if let swap = memory?.swapUsed, swap > 0 {
                ValueRow(label: "Swap", value: "\(Fmt.bytes(swap)) sur \(Fmt.bytes(memory?.swapTotal))")
            }
        }
    }

    private func disksCard(_ status: MoleStatus) -> some View {
        DashboardCard(title: "Disques", symbol: "internaldrive") {
            ForEach(status.disks ?? []) { disk in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(disk.mount == "/" ? "Disque système" : disk.mount)
                            .lineLimit(1)
                        if disk.external == true {
                            Text("externe").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(Fmt.bytes(disk.used)) / \(Fmt.bytes(disk.total))")
                            .font(.callout.monospacedDigit())
                    }
                    LevelBar(fraction: (disk.usedPercent ?? 0) / 100)
                    if let purgeable = disk.purgeable, purgeable > 0 {
                        Text("\(Fmt.bytes(purgeable)) purgeables par macOS")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let smart = disk.smartStatus, smart.lowercased() != "verified" {
                        Label("État SMART : \(smart)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func batteryCard(_ battery: MoleStatus.Battery, thermal: MoleStatus.Thermal?) -> some View {
        DashboardCard(title: "Batterie", symbol: "battery.75percent") {
            BigValue(value: battery.percent.map { "\($0) %" } ?? "—",
                     caption: battery.status == "AC" ? "Sur secteur" : battery.status)
            ValueRow(label: "Santé", value: battery.health ?? "—")
            ValueRow(label: "Capacité maximale", value: battery.capacity.map { "\($0) %" } ?? "—")
            ValueRow(label: "Cycles", value: Fmt.integer(battery.cycleCount))
            if let temp = thermal?.batteryTemp, temp > 0 {
                ValueRow(label: "Température", value: "\(Fmt.number(temp)) °C")
            }
            if let power = thermal?.systemPower, power > 0 {
                ValueRow(label: "Consommation", value: "\(Fmt.number(power)) W")
            }
        }
    }

    private func networkCard(_ status: MoleStatus) -> some View {
        DashboardCard(title: "Réseau", symbol: "network") {
            let active = (status.network ?? []).filter(\.isActive)
            if active.isEmpty {
                Text("Aucune interface connectée").foregroundStyle(.secondary)
            }
            ForEach(active) { interface in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(interface.name).font(.callout.monospaced())
                        Spacer()
                        Text(interface.ip ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 14) {
                        Label("\(Fmt.number(interface.rxRateMbs, decimals: 2)) Mo/s", systemImage: "arrow.down")
                        Label("\(Fmt.number(interface.txRateMbs, decimals: 2)) Mo/s", systemImage: "arrow.up")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            if let proxy = status.proxy, proxy.enabled == true {
                Label("Proxy / VPN actif (\(proxy.type ?? "?"))", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func processesCard(_ status: MoleStatus) -> some View {
        DashboardCard(title: "Processus les plus gourmands", symbol: "list.number") {
            ForEach(status.topProcesses ?? []) { process in
                HStack {
                    Text(process.name ?? process.command ?? "?")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(Fmt.percent(process.cpu))
                        .frame(width: 56, alignment: .trailing)
                    Text(Fmt.bytes(process.memoryBytes))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
                .font(.callout.monospacedDigit())
            }
            if let count = status.procs {
                Text("\(count) processus au total").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Graphique d'historique

    private func historyChart(_ value: KeyPath<StatusStore.Sample, Double>, color: Color) -> some View {
        Chart(store.samples) { sample in
            AreaMark(x: .value("Heure", sample.date), y: .value("%", sample[keyPath: value]))
                .foregroundStyle(color.opacity(0.15))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Heure", sample.date), y: .value("%", sample[keyPath: value]))
                .foregroundStyle(color)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...100)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine()
            }
        }
        .frame(height: 70)
    }
}
