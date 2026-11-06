//
//  MoleModels.swift
//  Modèles Codable pour les sorties JSON de Mole CLI :
//    mo status --json / --watch (NDJSON)
//    mo analyze --json [PATH]
//    mo history --json [--limit N]
//
//  Principe : presque tout est optionnel. Si Mole ajoute, renomme ou retire
//  un champ, le décodage continue de fonctionner au lieu de tout casser.
//

import Foundation

// MARK: - Décodage

enum MoleJSON {
    /// Décodeur partagé : les clés snake_case de Mole deviennent du camelCase.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    /// Décode un flux NDJSON (`mo status --watch`) ligne par ligne.
    /// Les lignes illisibles sont ignorées plutôt que d'interrompre le flux.
    static func statusStream(from handle: FileHandle) -> AsyncCompactMapSequence<AsyncLineSequence<FileHandle.AsyncBytes>, MoleStatus> {
        handle.bytes.lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(MoleStatus.self, from: data)
        }
    }
}

// MARK: - Dates
//
// Mole utilise trois formats différents :
//   status    : 2026-11-06T14:12:52.049951+01:00  (microsecondes, offset avec « : »)
//   deletions : 2026-11-05T16:22:14+0100          (offset sans « : »)
//   sessions  : 2026-11-06 14:10:50               (heure locale, sans fuseau)
// On garde donc les dates en String et on les parse à la demande.

enum MoleDate {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let compactOffset: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f
    }()

    private static let localNoZone: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let s = string, !s.isEmpty else { return nil }
        if let d = isoFrac.date(from: s) ?? iso.date(from: s) { return d }
        // Repli : on retire la partie fractionnaire (microsecondes) et on réessaie.
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let trimmed = String(s[..<dot]) + String(s[end...])
            if let d = iso.date(from: trimmed) { return d }
        }
        return compactOffset.date(from: s) ?? localNoZone.date(from: s)
    }
}

// MARK: - Statut de scan (analyze)

enum ScanStatus: String, Decodable {
    case complete, partial, unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ScanStatus(rawValue: raw) ?? .unknown
    }
}

// MARK: - mo status --json

struct MoleStatus: Decodable {
    let collectedAt: String?
    let host: String?
    let platform: String?
    let uptime: String?
    let uptimeSeconds: Int?
    let procs: Int?
    let hardware: Hardware?
    let healthScore: Int?
    let healthScoreMsg: String?
    let cpu: CPU?
    let gpu: [GPU]?
    let memory: Memory?
    let disks: [Disk]?
    let trashSize: Int64?
    let trashApprox: Bool?
    let diskIo: DiskIO?
    let network: [NetworkInterface]?
    let networkHistory: NetworkHistory?
    let proxy: Proxy?
    let batteries: [Battery]?
    let thermal: Thermal?
    let bluetooth: [BluetoothDevice]?
    let topProcesses: [Process]?
    let processCollectedAt: String?
    let processStale: Bool?
    let zombieCount: Int?
    let processWatch: ProcessWatch?
    // `sensors`, `zombie_parents` et `process_alerts` : format encore inconnu
    // (null ou tableaux vides dans l'échantillon). À ajouter quand on en verra un rempli.

    var collectedDate: Date? { MoleDate.parse(collectedAt) }

    struct Hardware: Decodable {
        let model: String?
        let cpuModel: String?
        let totalRam: String?
        let diskSize: String?
        let osVersion: String?
        let refreshRate: String?
    }

    struct CPU: Decodable {
        let usage: Double?
        let perCore: [Double]?
        let perCoreEstimated: Bool?
        let load1: Double?
        let load5: Double?
        let load15: Double?
        let coreCount: Int?
        let logicalCpu: Int?
        let pCoreCount: Int?
        let eCoreCount: Int?
    }

    struct GPU: Decodable {
        let name: String?
        /// -1 quand l'utilisation n'est pas disponible.
        let usage: Double?
        let memoryUsed: Int64?
        let memoryTotal: Int64?
        let coreCount: Int?
        let note: String?

        var usageIfAvailable: Double? {
            guard let u = usage, u >= 0 else { return nil }
            return u
        }
    }

    struct Memory: Decodable {
        let used: Int64?
        let total: Int64?
        let available: Int64?
        let usedPercent: Double?
        let swapUsed: Int64?
        let swapTotal: Int64?
        let cached: Int64?
        /// Peut être une chaîne vide.
        let pressure: String?
    }

    struct Disk: Decodable, Identifiable {
        let mount: String
        let device: String?
        let used: Int64?
        let total: Int64?
        let usedPercent: Double?
        let fstype: String?
        let external: Bool?
        let smartStatus: String?
        let purgeable: Int64?

        var id: String { mount }
    }

    struct DiskIO: Decodable {
        let readRate: Double?
        let writeRate: Double?
    }

    struct NetworkInterface: Decodable, Identifiable {
        let name: String
        let rxRateMbs: Double?
        let txRateMbs: Double?
        /// Chaîne vide si l'interface n'a pas d'adresse.
        let ip: String?

        var id: String { name }
        var isActive: Bool { !(ip ?? "").isEmpty }
    }

    struct NetworkHistory: Decodable {
        let rxHistory: [Double]?
        let txHistory: [Double]?
    }

    struct Proxy: Decodable {
        let enabled: Bool?
        let type: String?
        let host: String?
    }

    struct Battery: Decodable {
        let percent: Int?
        let status: String?
        let timeLeft: String?
        let health: String?
        let cycleCount: Int?
        /// Capacité maximale en % de la capacité d'origine.
        let capacity: Int?
    }

    struct Thermal: Decodable {
        /// 0 = non disponible (cas des Mac Apple Silicon sans accès capteur).
        let cpuTemp: Double?
        let gpuTemp: Double?
        let batteryTemp: Double?
        let fanSpeed: Int?
        let fanCount: Int?
        let systemPower: Double?
        let adapterPower: Double?
        let batteryPower: Double?
    }

    struct BluetoothDevice: Decodable, Identifiable {
        let name: String
        let connected: Bool?
        /// Texte libre, ex. « Right Battery Level: 96 % », souvent vide.
        let battery: String?

        var id: String { name }
    }

    struct Process: Decodable, Identifiable {
        let pid: Int
        let ppid: Int?
        let name: String?
        let command: String?
        let cpu: Double?
        /// Pourcentage de la RAM totale.
        let memory: Double?
        let memoryBytes: Int64?

        var id: Int { pid }
    }

    struct ProcessWatch: Decodable {
        let enabled: Bool?
        let cpuThreshold: Double?
        /// Format Go, ex. « 5m0s ».
        let window: String?
    }
}

// MARK: - mo analyze --json [PATH]

struct MoleAnalysis: Decodable {
    let scanStatus: ScanStatus?
    let path: String?
    /// true quand analyze est lancé sans chemin (vue globale de la machine).
    let overview: Bool?
    let entries: [Entry]?
    let largeFiles: [LargeFile]?
    let totalSize: Int64?
    let totalFiles: Int?

    struct Entry: Decodable, Identifiable {
        let scanStatus: ScanStatus?
        let name: String
        let path: String
        let size: Int64
        let isDir: Bool
        /// Présent seulement pour les fichiers.
        let lastAccess: String?

        var id: String { path }
        var lastAccessDate: Date? { MoleDate.parse(lastAccess) }

        /// Mole suffixe les liens symboliques par « → » dans `name`.
        var isSymlink: Bool { name.hasSuffix("→") }
        var displayName: String {
            isSymlink ? String(name.dropLast()).trimmingCharacters(in: .whitespaces) : name
        }
    }

    struct LargeFile: Decodable, Identifiable {
        let name: String
        let path: String
        let size: Int64

        var id: String { path }
    }
}

// MARK: - mo history --json [--limit N]

struct MoleHistory: Decodable {
    let logs: Logs?
    let limit: Int?
    let sessions: [Session]?
    let deletions: [Deletion]?

    struct Logs: Decodable {
        let operations: String?
        let deletions: String?
    }

    struct Session: Decodable, Identifiable {
        let command: String
        /// Vide pour certaines commandes (ex. uninstall sans action).
        let runId: String?
        /// « command » ou « run » dans les échantillons vus.
        let attribution: String?
        let startedAt: String?
        let endedAt: String?
        let items: Int?
        /// Taille formatée par Mole, ex. « 0B ». Pas de valeur numérique brute.
        let size: String?
        let operationCount: Int?
        let failedTasks: Int?
        let actions: Actions?

        var id: String { (runId?.isEmpty == false ? runId! : "\(command)-\(startedAt ?? "")") }
        var startDate: Date? { MoleDate.parse(startedAt) }
        var endDate: Date? { MoleDate.parse(endedAt) }
        var duration: TimeInterval? {
            guard let s = startDate, let e = endDate else { return nil }
            return e.timeIntervalSince(s)
        }
    }

    struct Actions: Decodable {
        let removed: Int?
        let trashed: Int?
        let skipped: Int?
        let failed: Int?
        let rebuilt: Int?
        let other: Int?
    }

    struct Deletion: Decodable, Identifiable {
        let timestamp: String
        /// « trash » ou suppression définitive.
        let mode: String?
        let status: String?
        let sizeKb: Int64?
        let path: String

        var id: String { "\(timestamp)|\(path)" }
        var date: Date? { MoleDate.parse(timestamp) }
        var sizeBytes: Int64? { sizeKb.map { $0 * 1024 } }
        var wentToTrash: Bool { mode == "trash" }
    }
}
