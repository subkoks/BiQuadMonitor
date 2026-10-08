import Foundation
import Darwin
import CFileLock
import SQLite3
import SignalCore

public enum SessionStoreError: LocalizedError {
    case open, operation, incompatible, corrupt, missing, export, inUse, ownershipRequired
    public var errorDescription: String? {
        switch self {
        case .open: return "Measurement history could not be opened. Existing data was preserved."
        case .operation: return "Measurement history could not be saved. Check available disk space."
        case .incompatible: return "This history database belongs to another app or a newer version. It was not replaced."
        case .corrupt: return "Saved measurement data could not be read. The database was preserved."
        case .missing: return "The selected session is no longer available."
        case .export: return "The export could not be completed at the selected location."
        case .inUse: return "Another BiQuad Monitor instance is using measurement history. Quit that instance before opening this one."
        case .ownershipRequired: return "Recovery requires exclusive ownership of measurement history. Existing sessions were preserved."
        }
    }
}

/// A persistent lock-file inode prevents a second process from recovering a live
/// writer's sessions. Never unlink it on release: that would permit split ownership.
private final class WriterLock: @unchecked Sendable {
    private let descriptor: Int32
    init(path: String) throws {
        descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SessionStoreError.open }
        let lockError = biquad_try_exclusive_lock(descriptor)
        guard lockError == 0 else {
            Darwin.close(descriptor)
            if lockError == EWOULDBLOCK { throw SessionStoreError.inUse }
            throw SessionStoreError.open
        }
    }
    deinit { Darwin.close(descriptor) }
}

private final class Database: @unchecked Sendable {
    var handle: OpaquePointer?
    private let writerLock: WriterLock?
    var ownsRecovery: Bool { writerLock != nil }
    init(path: String, exclusiveWriter: Bool = false) throws {
        writerLock = exclusiveWriter && path != ":memory:" ? try WriterLock(path: path + ".writer-lock") : nil
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(handle); handle = nil; throw SessionStoreError.open
        }
        sqlite3_busy_timeout(handle, 3000)
    }
    deinit { sqlite3_close(handle) }
}

public struct ExportPrivacy: Sendable {
    public var includeCell: Bool
    public var includeNamesAndNotes: Bool
    public init(includeCell: Bool = false, includeNamesAndNotes: Bool = false) {
        self.includeCell = includeCell; self.includeNamesAndNotes = includeNamesAndNotes
    }
}

public enum ExportFormat: String, CaseIterable, Sendable { case csv = "CSV", json = "JSON" }

/// One actor owns every SQL operation. Only fixed SQL and bound values reach SQLite.
public actor SessionStore {
    private let database: Database
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let inMemory: Bool
    private static let applicationID: Int64 = 0x42514D31

    /// The application must use `exclusiveWriter: true` for its on-disk store.
    /// Non-exclusive stores support inspection/tests, but cannot recover sessions.
    /// Ownership is acquired before opening SQLite and lasts until deinitialization.
    public init(url: URL? = nil, exclusiveWriter: Bool = false) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        inMemory = url == nil
        database = try Database(path: url?.path ?? ":memory:", exclusiveWriter: exclusiveWriter)
        // Foundation's native Date encoding preserves the original Double exactly.
        // Epoch conversion is reserved for external exports, not database round-trips.
        encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        let db = database.handle
        func scalar(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw SessionStoreError.open }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw SessionStoreError.open }
            return sqlite3_column_int64(statement, 0)
        }
        let appID = try scalar("PRAGMA application_id"), version = try scalar("PRAGMA user_version")
        let tableCount = try scalar("SELECT count(*) FROM sqlite_master WHERE type='table'")
        guard version <= 1, appID == Self.applicationID || (appID == 0 && version == 0 && tableCount == 0) else { throw SessionStoreError.incompatible }
        if let url { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SessionStoreError.open }
        }
        try execute("PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;")
        if version == 0 {
            // Version 0 is accepted only for an empty database, never an unknown file.
            try execute("""
                BEGIN IMMEDIATE;
                CREATE TABLE sessions (id TEXT PRIMARY KEY, started REAL NOT NULL, ended REAL, pinned INTEGER NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE trials (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, started REAL NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE readings (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, trial_id TEXT REFERENCES trials(id), observed REAL NOT NULL, payload BLOB NOT NULL);
                CREATE TABLE events (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, observed REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX readings_by_session ON readings(session_id, observed);
                CREATE INDEX readings_by_trial ON readings(trial_id, observed);
                CREATE INDEX events_by_session ON events(session_id, observed);
                PRAGMA application_id=1112624433;
                PRAGMA user_version=1;
                COMMIT;
                """)
        }
        if let url { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    public static func defaultURL() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("BiQuadMonitor", isDirectory: true).appendingPathComponent("measurements.sqlite")
    }

    private enum Value { case text(String), number(Double), blob(Data), null }
    private func statement(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(database.handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else { throw SessionStoreError.operation }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1), status: Int32
            switch value {
            case .text(let string): status = sqlite3_bind_text(raw, index, string, -1, transient)
            case .number(let number): status = sqlite3_bind_double(raw, index, number)
            case .blob(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(raw, index, $0.baseAddress, Int32(data.count), transient) }
            case .null: status = sqlite3_bind_null(raw, index)
            }
            guard status == SQLITE_OK else { sqlite3_finalize(raw); throw SessionStoreError.operation }
        }
        return raw
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        let raw = try statement(sql, values); defer { sqlite3_finalize(raw) }
        guard sqlite3_step(raw) == SQLITE_DONE else { throw SessionStoreError.operation }
    }
    private func decode<T: Decodable>(_ type: T.Type, _ raw: OpaquePointer, column: Int32 = 0) throws -> T {
        let count = Int(sqlite3_column_bytes(raw, column))
        guard count > 0, count < 2_000_000, let bytes = sqlite3_column_blob(raw, column) else { throw SessionStoreError.corrupt }
        do { return try decoder.decode(type, from: Data(bytes: bytes, count: count)) }
        catch { throw SessionStoreError.corrupt }
    }
    private func rows<T: Decodable>(_ type: T.Type, _ sql: String, _ values: [Value] = []) throws -> [T] {
        let raw = try statement(sql, values); defer { sqlite3_finalize(raw) }
        var result: [T] = []
        while true {
            let status = sqlite3_step(raw)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw SessionStoreError.corrupt }
            result.append(try decode(type, raw))
        }
    }

    public func save(_ session: MeasurementSession) throws {
        try execute("INSERT INTO sessions (id,started,ended,pinned,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET ended=excluded.ended,pinned=excluded.pinned,payload=excluded.payload", [.text(session.id.uuidString), .number(session.started.timeIntervalSince1970), session.ended.map { .number($0.timeIntervalSince1970) } ?? .null, .number(session.pinned ? 1 : 0), .blob(try encoder.encode(session))])
    }
    public func save(_ trial: AntennaTrial) throws {
        try execute("INSERT INTO trials (id,session_id,started,payload) VALUES (?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", [.text(trial.id.uuidString), .text(trial.sessionID.uuidString), .number(trial.started.timeIntervalSince1970), .blob(try encoder.encode(trial))])
    }
    public func append(_ record: SignalRecord) throws {
        try execute("INSERT INTO readings (id,session_id,trial_id,observed,payload) VALUES (?,?,?,?,?)", [.text(record.id.uuidString), .text(record.sessionID.uuidString), record.trialID.map { .text($0.uuidString) } ?? .null, .number(record.sample.date.timeIntervalSince1970), .blob(try encoder.encode(record))])
    }
    public func append(_ event: MeasurementEvent) throws {
        try execute("INSERT INTO events (id,session_id,observed,payload) VALUES (?,?,?,?)", [.text(event.id.uuidString), .text(event.sessionID.uuidString), .number(event.date.timeIntervalSince1970), .blob(try encoder.encode(event))])
    }
    public func sessions() throws -> [MeasurementSession] { try rows(MeasurementSession.self, "SELECT payload FROM sessions ORDER BY started DESC LIMIT 1000") }
    public func snapshot(_ id: UUID, limit: Int = 10_000) throws -> SessionSnapshot {
        guard let session = try rows(MeasurementSession.self, "SELECT payload FROM sessions WHERE id=?", [.text(id.uuidString)]).first else { throw SessionStoreError.missing }
        let trials = try rows(AntennaTrial.self, "SELECT payload FROM trials WHERE session_id=? ORDER BY started", [.text(id.uuidString)])
        let records = try rows(SignalRecord.self, "SELECT payload FROM (SELECT observed,payload FROM readings WHERE session_id=? ORDER BY observed DESC LIMIT ?) ORDER BY observed", [.text(id.uuidString), .number(Double(max(1, min(limit, 20_000))))])
        let events = try rows(MeasurementEvent.self, "SELECT payload FROM (SELECT observed,payload FROM events WHERE session_id=? ORDER BY observed DESC LIMIT 1000) ORDER BY observed", [.text(id.uuidString)])
        return SessionSnapshot(session: session, trials: trials, records: records, events: events)
    }
    public func trialRecords(_ id: UUID) throws -> [SignalRecord] { try rows(SignalRecord.self, "SELECT payload FROM readings WHERE trial_id=? ORDER BY observed", [.text(id.uuidString)]) }
    public func count(_ id: UUID) throws -> Int {
        let raw = try statement("SELECT count(*) FROM readings WHERE session_id=?", [.text(id.uuidString)]); defer { sqlite3_finalize(raw) }
        guard sqlite3_step(raw) == SQLITE_ROW else { throw SessionStoreError.corrupt }
        return Int(sqlite3_column_int64(raw, 0))
    }
    /// Run once at application startup, before creating a new session.
    public func recoverInterruptedSessions() throws {
        guard inMemory || database.ownsRecovery else { throw SessionStoreError.ownershipRequired }
        let open = try rows(MeasurementSession.self, "SELECT payload FROM sessions WHERE ended IS NULL")
        try execute("BEGIN IMMEDIATE")
        do {
            for var session in open {
                let last = try rows(SignalRecord.self, "SELECT payload FROM readings WHERE session_id=? ORDER BY observed DESC LIMIT 1", [.text(session.id.uuidString)]).first
                session.ended = last?.sample.date ?? session.started
                let trials = try rows(AntennaTrial.self, "SELECT payload FROM trials WHERE session_id=?", [.text(session.id.uuidString)])
                for var trial in trials where trial.ended == nil {
                    trial.phase = .cancelled; trial.ended = max(trial.started, session.ended!)
                    trial.recordedSeconds = min(trial.targetSeconds, max(0, trial.ended!.timeIntervalSince(trial.recordingStarted ?? trial.ended!)))
                    try save(trial)
                }
                try save(session)
                try append(MeasurementEvent(sessionID: session.id, kind: .recovery, message: "Previous collection ended unexpectedly. Saved samples were recovered; unfinished trials are incomplete."))
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    public func prune(before date: Date) throws {
        // Retention never removes active sessions or explicitly pinned experiments.
        try execute("DELETE FROM sessions WHERE pinned=0 AND ended IS NOT NULL AND ended<?", [.number(date.timeIntervalSince1970)])
    }
    public func backup(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw SessionStoreError.operation }
        let destination = try Database(path: url.path)
        guard let backup = sqlite3_backup_init(destination.handle, "main", database.handle, "main") else { throw SessionStoreError.operation }
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else { throw SessionStoreError.operation }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Stream rows directly to a private temporary file; exports are never chart-limited.
    public func export(_ id: UUID, to url: URL, format: ExportFormat, privacy: ExportPrivacy) throws {
        let snapshot = try snapshot(id, limit: 1)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".biquad-export-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SessionStoreError.export }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = try FileHandle(forWritingTo: temporary)
        defer { try? file.close() }
        func write(_ string: String) throws { try file.write(contentsOf: Data(string.utf8)) }
        let exportEncoder = JSONEncoder(); exportEncoder.outputFormatting = [.sortedKeys]; exportEncoder.dateEncodingStrategy = .millisecondsSince1970
        func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try exportEncoder.encode(value), as: UTF8.self) }
        func quoted(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = ["=", "+", "-", "@"].contains(where: { trimmed.hasPrefix($0) }) || value.hasPrefix("\t") || value.hasPrefix("\r") ? "'" + value : value
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var session = snapshot.session
        if !privacy.includeNamesAndNotes { session.name = "Measurement session" }
        var trials = snapshot.trials
        if !privacy.includeNamesAndNotes {
            for i in trials.indices { trials[i].name = "Trial \(i + 1)"; trials[i].notes = ""; trials[i].orientation = "" }
        }
        let names = Dictionary(uniqueKeysWithValues: trials.map { ($0.id, $0.name) })
        if format == .json {
            try write("{\"schemaVersion\":1,\"dateUnit\":\"millisecondsSince1970\",\"session\":\(try encoded(session)),\"trials\":\(try encoded(trials)),\"records\":[")
        } else {
            try write("row_type,session_id,trial_id,trial_name,source,timestamp,SINR_dB,RSRQ_dB,RSRP_dBm,RSSI,RSSI_unit,band,cell,cellular_connected,phase,event_kind,event_message,session_name,trial_notes,trial_orientation\n")
            func metadata(_ type: String, trial: AntennaTrial? = nil) throws {
                var fields = Array(repeating: "", count: 20)
                fields[0] = type; fields[1] = id.uuidString; fields[2] = trial?.id.uuidString ?? ""
                fields[3] = quoted(trial?.name ?? ""); fields[4] = session.demo ? "demo" : "router"
                fields[14] = trial?.phase.rawValue ?? ""; fields[17] = quoted(session.name)
                fields[18] = quoted(trial?.notes ?? ""); fields[19] = quoted(trial?.orientation ?? "")
                try write(fields.joined(separator: ",") + "\n")
            }
            try metadata("session")
            for trial in trials { try metadata("trial", trial: trial) }
        }
        let raw = try statement("SELECT payload FROM readings WHERE session_id=? ORDER BY observed", [.text(id.uuidString)])
        defer { sqlite3_finalize(raw) }
        let dates = ISO8601DateFormatter(); dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var first = true
        while true {
            let status = sqlite3_step(raw)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw SessionStoreError.corrupt }
            let record = try decode(SignalRecord.self, raw), s = record.sample
            if format == .json {
                var details = s.details
                if !privacy.includeCell { details.removeValue(forKey: "PCID") }
                let sanitized = SignalSample(date: s.date, sinr: s.sinr, rsrq: s.rsrq, rsrp: s.rsrp, rssi: s.rssi, band: s.band, cell: privacy.includeCell ? s.cell : "redacted", carrier: s.carrier, connected: s.connected, rssiUnits: s.rssiUnits, details: details)
                let output = SignalRecord(id: record.id, sessionID: record.sessionID, trialID: record.trialID, sample: sanitized, phase: record.phase, segment: record.segment, expectedInterval: record.expectedInterval)
                try write((first ? "" : ",") + (try encoded(output))); first = false
            } else {
                let values = s.values.map { $0.map { String($0) } ?? "" }
                let fields = ["sample", id.uuidString, record.trialID?.uuidString ?? "", quoted(record.trialID.flatMap { names[$0] } ?? ""), session.demo ? "demo" : "router", dates.string(from: s.date)] + values + [quoted(s.rssiUnits.rawValue), quoted(s.band), quoted(privacy.includeCell ? s.cell : "redacted"), s.connected ? "true" : "false", record.phase?.rawValue ?? "", "", "", quoted(session.name), "", ""]
                try write(fields.joined(separator: ",") + "\n")
            }
        }
        let events = try rows(MeasurementEvent.self, "SELECT payload FROM events WHERE session_id=? ORDER BY observed", [.text(id.uuidString)])
            .filter { privacy.includeNamesAndNotes || $0.kind != .note }
        if format == .json { try write("],\"events\":\(try encoded(events))}\n") }
        else {
            for event in events {
                let fields = ["event", id.uuidString, "", "", session.demo ? "demo" : "router", dates.string(from: event.date)] + Array(repeating: "", count: 9) + [event.kind.rawValue, quoted(event.message), quoted(session.name), "", ""]
                try write(fields.joined(separator: ",") + "\n")
            }
        }
        try file.synchronize(); try file.close()
        guard rename(temporary.path, url.path) == 0 else { throw SessionStoreError.export }
    }
}
