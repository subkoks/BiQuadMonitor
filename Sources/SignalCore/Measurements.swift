import Foundation

public enum RSSIUnit: String, Codable, Sendable { case rawIndex = "raw index", dBm, unknown }

public enum Metric: String, CaseIterable, Codable, Identifiable, Sendable {
    case sinr = "SINR", rsrq = "RSRQ", rsrp = "RSRP", rssi = "RSSI"
    public var id: String { rawValue }
    public var index: Int { Self.allCases.firstIndex(of: self)! }
    public func value(in sample: SignalSample) -> Double? { sample.values[index] }
    public func unit(for sample: SignalSample?) -> String {
        self == .rssi ? (sample?.rssiUnits.rawValue ?? "raw index") : (self == .rsrp ? "dBm" : "dB")
    }
    public var title: String {
        switch self {
        case .sinr: return "Signal quality"
        case .rsrq: return "Reference signal quality"
        case .rsrp: return "Reference signal power"
        case .rssi: return "Received signal strength"
        }
    }
}

public enum ReadingState: String, Codable, Sendable {
    case setup, connecting, live, stale, offline, paused, signInRequired, noService, demo
    public var label: String {
        switch self {
        case .setup: return "Setup"
        case .connecting: return "Connecting"
        case .live: return "Live"
        case .stale: return "Stale"
        case .offline: return "Offline"
        case .paused: return "Paused"
        case .signInRequired: return "Sign in"
        case .noService: return "No cellular service"
        case .demo: return "Demo"
        }
    }
    public var hasCurrentReadings: Bool { self == .live || self == .demo }
}

public enum MenuPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case full = "Full", compact = "Compact", custom = "Custom"
    public var id: String { rawValue }
}

public enum DisplayFormat {
    public static func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        let normalized = abs(value) < 0.05 ? 0 : value
        return String(format: normalized.rounded() == normalized ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), normalized)
            .replacingOccurrences(of: "-", with: "−")
    }
    public static func menu(sample: SignalSample?, state: ReadingState, preset: MenuPreset = .full, metrics: [Metric] = Metric.allCases) -> String {
        guard state.hasCurrentReadings, let sample else { return "LTE · \(state.label)" }
        let prefix = state == .demo ? "DEMO" : "LTE"
        if preset == .compact { return "\(prefix) B\(sample.band) | SINR \(number(sample.sinr))" }
        let chosen = preset == .full ? Metric.allCases : Metric.allCases.filter { metrics.contains($0) }
        return (["\(prefix) BAND \(sample.band)"] + chosen.map { "\($0.rawValue) \(number($0.value(in: sample)))" }).joined(separator: " | ")
    }
}

public struct MeasurementSession: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let started: Date
    public var ended: Date?
    public var pinned: Bool
    public let demo: Bool
    public let adapter: String
    public init(id: UUID = UUID(), name: String, started: Date = Date(), demo: Bool = false, pinned: Bool = false) {
        self.id = id; self.name = name; self.started = started; self.demo = demo; self.pinned = pinned
        adapter = "cudy-lt500-v2/2.4.16"
    }
}

public enum TrialPhase: String, Codable, Sendable { case settling, recording, finished, cancelled }

public struct AntennaTrial: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public var name: String
    public var notes: String
    public var orientation: String
    public let started: Date
    public var recordingStarted: Date?
    public var ended: Date?
    public var phase: TrialPhase
    public let settleSeconds: Double
    public let targetSeconds: Double
    public var recordedSeconds: Double
    public init(id: UUID = UUID(), sessionID: UUID, name: String, notes: String = "", orientation: String = "", started: Date = Date(), settleSeconds: Double = 60, targetSeconds: Double = 120) {
        self.id = id; self.sessionID = sessionID; self.name = name; self.notes = notes; self.orientation = orientation; self.started = started
        self.settleSeconds = max(0, settleSeconds); self.targetSeconds = max(5, targetSeconds); recordedSeconds = 0
        phase = settleSeconds > 0 ? .settling : .recording
        recordingStarted = phase == .recording ? started : nil
    }
}

public struct SignalRecord: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let trialID: UUID?
    public let sample: SignalSample
    public let phase: TrialPhase?
    public let segment: Int
    public let expectedInterval: Double
    public init(id: UUID = UUID(), sessionID: UUID, trialID: UUID? = nil, sample: SignalSample, phase: TrialPhase? = nil, segment: Int = 0, expectedInterval: Double = 5) {
        self.id = id; self.sessionID = sessionID; self.trialID = trialID; self.sample = sample; self.phase = phase; self.segment = segment
        self.expectedInterval = max(1, expectedInterval)
    }
}

public struct MeasurementEvent: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case connection, gap, contextChanged, trialStarted, trialFinished, note, pause, recovery }
    public let id: UUID
    public let sessionID: UUID
    public let date: Date
    public let kind: Kind
    public let message: String
    public init(id: UUID = UUID(), sessionID: UUID, date: Date = Date(), kind: Kind, message: String) {
        self.id = id; self.sessionID = sessionID; self.date = date; self.kind = kind; self.message = String(message.prefix(2000))
    }
}

public struct SessionSnapshot: Codable, Sendable {
    public var session: MeasurementSession
    public var trials: [AntennaTrial]
    public var records: [SignalRecord]
    public var events: [MeasurementEvent]
    public init(session: MeasurementSession, trials: [AntennaTrial] = [], records: [SignalRecord] = [], events: [MeasurementEvent] = []) {
        self.session = session; self.trials = trials; self.records = records; self.events = events
    }
}

public struct Distribution: Equatable, Sendable {
    public let count: Int
    public let median: Double
    public let p10: Double
    public let p90: Double
    public let q1: Double
    public let q3: Double
    public var iqr: Double { q3 - q1 }
    public init?(_ values: [Double]) {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        func quantile(_ p: Double) -> Double {
            let position = Double(sorted.count - 1) * p
            let low = Int(position), high = min(low + 1, sorted.count - 1)
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
        count = sorted.count; median = quantile(0.5); p10 = quantile(0.1); p90 = quantile(0.9); q1 = quantile(0.25); q3 = quantile(0.75)
    }
}

public enum TrialAnalysis {
    public static func readings(_ records: [SignalRecord], trial: AntennaTrial) -> [SignalRecord] {
        records.filter { $0.trialID == trial.id && $0.phase == .recording && $0.sample.connected }
    }
    public static func statistics(_ records: [SignalRecord], metric: Metric) -> Distribution? {
        Distribution(records.compactMap { metric.value(in: $0.sample) })
    }
    public static func context(_ records: [SignalRecord]) -> String? {
        guard let first = records.first, first.sample.connected,
              !["", "—", "n/a", "unknown"].contains(first.sample.band.lowercased()), !["", "—", "n/a", "unknown"].contains(first.sample.cell.lowercased()),
              first.sample.rssiUnits != .unknown,
              records.allSatisfy({ $0.sample.connected && $0.sample.band == first.sample.band && $0.sample.cell == first.sample.cell && $0.sample.rssiUnits == first.sample.rssiUnits }) else { return nil }
        return "\(first.sample.band)|\(first.sample.cell)|\(first.sample.rssiUnits.rawValue)"
    }
    public static func comparable(_ lhs: [SignalRecord], _ rhs: [SignalRecord]) -> Bool {
        guard let a = context(lhs), let b = context(rhs) else { return false }
        return a == b
    }
    public static func coverage(_ records: [SignalRecord], duration: Double, interval: Double) -> Double {
        guard duration > 0, interval > 0 else { return 0 }
        let valid = records.filter { $0.sample.connected && $0.sample.values.allSatisfy { $0 != nil } }.count
        return min(1, Double(valid) / max(1, ceil(duration / interval)))
    }
}

public struct ChartPoint: Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let value: Double
    public let series: Int
}

public enum ChartData {
    /// Preserve endpoints and extrema in each bucket; never merge separate series.
    /// Raw measurements remain in the store and exports. Pathological many-gap
    /// traces show the latest segments within the display budget.
    public static func displayPoints(_ records: [SignalRecord], metric: Metric, budget: Int = 800) -> [ChartPoint] {
        var raw = points(records, metric: metric)
        let limit = max(8, budget)
        if metric == .rssi, let unit = records.last?.sample.rssiUnits {
            let matching = Set(records.filter { $0.sample.rssiUnits == unit }.map(\.id))
            raw.removeAll { !matching.contains($0.id) }
        }
        guard raw.count > limit else { return raw }
        let groups = Dictionary(grouping: raw, by: \.series).sorted { $0.key < $1.key }
        let stride = max(4, Int(ceil(Double(raw.count) / Double(limit) * 4)))
        var output: [ChartPoint] = []
        for (_, group) in groups {
            for start in Swift.stride(from: 0, to: group.count, by: stride) {
                let bucket = Array(group[start..<min(start + stride, group.count)])
                let chosen = [bucket.first!, bucket.min(by: { $0.value < $1.value })!, bucket.max(by: { $0.value < $1.value })!, bucket.last!]
                var ids = Set<UUID>()
                output += chosen.sorted { $0.date < $1.date }.filter { ids.insert($0.id).inserted }
            }
        }
        return Array(output.suffix(limit))
    }
    /// Segments prevent interpolation through missing metrics, outages or cell changes.
    public static func points(_ records: [SignalRecord], metric: Metric) -> [ChartPoint] {
        var result: [ChartPoint] = [], series = 0
        var previous: SignalRecord?
        for record in records.sorted(by: { $0.sample.date < $1.sample.date }) {
            if let last = previous, record.segment != last.segment || record.sample.band != last.sample.band || record.sample.cell != last.sample.cell || record.sample.rssiUnits != last.sample.rssiUnits || record.sample.date.timeIntervalSince(last.sample.date) > last.expectedInterval * 2.5 { series += 1 }
            previous = record
            guard record.sample.connected, let value = metric.value(in: record.sample), value.isFinite else { series += 1; continue }
            result.append(ChartPoint(id: record.id, date: record.sample.date, value: value, series: series))
        }
        return result
    }
}
