import XCTest
import SignalCore
@testable import SessionStore

final class SessionStoreTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testPersistsTrialsAndRecoversFromReopen() async throws {
        let url = try directory().appendingPathComponent("history.sqlite")
        let store = try SessionStore(url: url)
        let session = MeasurementSession(name: "Experiment")
        let trial = AntennaTrial(sessionID: session.id, name: "A", settleSeconds: 0)
        try await store.save(session); try await store.save(trial)
        let record = SignalRecord(sessionID: session.id, trialID: trial.id, sample: SignalSample(sinr: 8, rsrq: -9, rsrp: -96, rssi: 23), phase: .recording)
        try await store.append(record)
        let reopened = try SessionStore(url: url)
        let snapshot = try await reopened.snapshot(session.id)
        XCTAssertEqual(snapshot.trials, [trial]); XCTAssertEqual(snapshot.records, [record])
    }
    func testRetentionProtectsActiveAndPinnedSessions() async throws {
        let store = try SessionStore()
        var old = MeasurementSession(name: "Routine", started: .distantPast); old.ended = .distantPast
        var pinned = MeasurementSession(name: "Saved", started: .distantPast, pinned: true); pinned.ended = .distantPast
        let active = MeasurementSession(name: "Active", started: .distantPast)
        for session in [old, pinned, active] { try await store.save(session) }
        try await store.prune(before: Date())
        let ids = try await store.sessions().map(\.id)
        XCTAssertEqual(Set(ids), Set([pinned.id, active.id]))
    }
    func testExportIsCompleteAndPrivateByDefault() async throws {
        let store = try SessionStore(), folder = try directory()
        let session = MeasurementSession(name: "PRIVATE-NAME", demo: true)
        let trial = AntennaTrial(sessionID: session.id, name: "  =FORMULA", notes: "PRIVATE-NOTE", orientation: "PRIVATE-ORIENTATION", settleSeconds: 0)
        try await store.save(session); try await store.save(trial)
        for i in 0..<5 {
            try await store.append(SignalRecord(sessionID: session.id, trialID: trial.id, sample: SignalSample(date: Date(timeIntervalSince1970: Double(i)), sinr: Double(i), rsrq: -9, rsrp: -96, rssi: 23, cell: "PRIVATE-CELL", details: ["PCID": "PRIVATE-PCI"]), phase: .recording))
        }
        try await store.append(MeasurementEvent(sessionID: session.id, kind: .note, message: "PRIVATE-NOTE"))
        let json = folder.appendingPathComponent("export.json")
        try await store.export(session.id, to: json, format: .json, privacy: ExportPrivacy())
        let text = try String(contentsOf: json)
        XCTAssertFalse(text.contains("PRIVATE-")); XCTAssertFalse(text.contains("FORMULA"))
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual((object["records"] as? [Any])?.count, 5)
        let csv = folder.appendingPathComponent("export.csv")
        try await store.export(session.id, to: csv, format: .csv, privacy: ExportPrivacy(includeNamesAndNotes: true))
        let csvText = try String(contentsOf: csv)
        XCTAssertTrue(csvText.contains("'  =FORMULA"))
        XCTAssertTrue(csvText.contains("PRIVATE-NAME"))
        XCTAssertTrue(csvText.contains("PRIVATE-NOTE"))
        XCTAssertTrue(csvText.contains("PRIVATE-ORIENTATION"))
        XCTAssertFalse(csvText.contains("PRIVATE-CELL"))
        let empty = AntennaTrial(sessionID: session.id, name: "Empty trial", notes: "zero readings")
        try await store.save(empty)
        try await store.export(session.id, to: csv, format: .csv, privacy: ExportPrivacy(includeNamesAndNotes: true))
        XCTAssertTrue(try String(contentsOf: csv).contains("zero readings"))
        try await store.export(session.id, to: csv, format: .csv, privacy: ExportPrivacy())
        XCTAssertFalse(try String(contentsOf: csv).contains("PRIVATE-"))
    }
    func testBackupRestoresAllRows() async throws {
        let folder = try directory(), store = try SessionStore(url: folder.appendingPathComponent("original.sqlite"))
        let session = MeasurementSession(name: "Recoverable")
        try await store.save(session)
        let backupURL = folder.appendingPathComponent("backup.sqlite")
        try await store.backup(to: backupURL)
        let restored = try SessionStore(url: backupURL)
        let sessions = try await restored.sessions()
        XCTAssertEqual(sessions, [session])
    }
    func testForeignKeyFailureDoesNotCreateOrphanRecord() async throws {
        let store = try SessionStore()
        do {
            try await store.append(SignalRecord(sessionID: UUID(), sample: SignalSample(sinr: 8, rsrq: -9, rsrp: -96, rssi: 23)))
            XCTFail("Missing session must reject the record")
        } catch SessionStoreError.operation { }
    }
    func testRecoveryPreservesSamplesAndMarksUnfinishedTrialIncomplete() async throws {
        let store = try SessionStore()
        let session = MeasurementSession(name: "Interrupted")
        let trial = AntennaTrial(sessionID: session.id, name: "Trial", settleSeconds: 0)
        try await store.save(session); try await store.save(trial)
        let reading = SignalRecord(sessionID: session.id, trialID: trial.id, sample: SignalSample(sinr: 8, rsrq: -9, rsrp: -96, rssi: 23), phase: .recording)
        try await store.append(reading)
        try await store.recoverInterruptedSessions()
        let snapshot = try await store.snapshot(session.id)
        XCTAssertNotNil(snapshot.session.ended)
        XCTAssertEqual(snapshot.trials[0].phase, .cancelled)
        XCTAssertEqual(snapshot.records, [reading])
        XCTAssertEqual(snapshot.events.last?.kind, .recovery)
        try await store.recoverInterruptedSessions()
        let again = try await store.snapshot(session.id)
        XCTAssertEqual(again.events.count, 1)
    }

    func testSecondWriterCannotRecoverLiveSession() async throws {
        let url = try directory().appendingPathComponent("exclusive.sqlite")
        let first = try SessionStore(url: url, exclusiveWriter: true)
        let session = MeasurementSession(name: "Active writer")
        try await first.save(session)
        XCTAssertThrowsError(try SessionStore(url: url, exclusiveWriter: true)) { error in
            guard case SessionStoreError.inUse = error else { return XCTFail("Expected writer ownership error") }
        }
        let inspection = try SessionStore(url: url)
        do { try await inspection.recoverInterruptedSessions(); XCTFail("Unowned recovery must fail") }
        catch SessionStoreError.ownershipRequired { }
        let snapshot = try await first.snapshot(session.id)
        XCTAssertNil(snapshot.session.ended)
    }

}
