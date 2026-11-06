import Foundation

/// Mises en forme partagées par les vues natives.
enum Fmt {
    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(0))) + " %"
    }

    static func number(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }

    static func integer(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted()
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = [.hour, .minute, .second]
        f.maximumUnitCount = 2
        return f
    }()

    static func duration(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds >= 0 else { return "—" }
        if seconds < 1 { return "< 1 s" }
        return durationFormatter.string(from: seconds) ?? "—"
    }
}
