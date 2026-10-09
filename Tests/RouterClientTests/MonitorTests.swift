import XCTest
import SignalCore
@testable import BiQuadMonitor

private actor ConnectionFixture: RouterConnection {
    var polls = 0
    var mode = 0
    func setMode(_ mode: Int) { self.mode = mode }
    func count() -> Int { polls }
    func login(password: String) async throws -> SignalSample { try await Task.sleep(nanoseconds: 30_000_000); return reading() }
    nonisolated func close() { }
    func reading() -> SignalSample { SignalSample(sinr: 8, rsrq: -9, rsrp: -96, rssi: 23, band: "3", cell: "FIXTURE") }
    func poll() async throws -> SignalSample {
        polls += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        if mode == 1 { throw MonitorError.transport }
        if mode == 2 { throw MonitorError.login }
        return reading()
    }
}

final class MonitorTests: XCTestCase {
    @MainActor func testOutageMarksStaleKeepsHistoryAndRecoversWithoutOverlap() async throws {
        let fixture = ConnectionFixture()
        let monitor = Monitor(ephemeral: true, clientFactory: { _, _ in fixture })
        await monitor.connect(password: "synthetic", persistSettings: false)
        XCTAssertEqual(monitor.state, .live)
        await fixture.setMode(1)
        let first = Task { await monitor.refresh() }
        await Task.yield()
        await monitor.refresh()
        await first.value
        let requests = await fixture.count()
        XCTAssertEqual(requests, 1, "Only one request should be in flight")
        XCTAssertEqual(monitor.state, .stale)
        XCTAssertEqual(monitor.sample?.sinr, 8)
        XCTAssertEqual(monitor.totalSamples, 1)
        XCTAssertEqual(monitor.menuTitle, "LTE · Stale")
        await fixture.setMode(0)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .live)
        XCTAssertEqual(monitor.totalSamples, 2)
        XCTAssertNotEqual(monitor.records.first?.segment, monitor.records.last?.segment)
        await monitor.shutdown()
    }
    @MainActor func testExpiredSessionStopsCollectionAndManualPauseSurvivesWake() async throws {
        let fixture = ConnectionFixture()
        let monitor = Monitor(ephemeral: true, clientFactory: { _, _ in fixture })
        await monitor.connect(password: "synthetic", persistSettings: false)
        await monitor.pause(); await monitor.handleSleep(); await monitor.handleWake()
        XCTAssertEqual(monitor.state, .paused)
        await monitor.resume()
        XCTAssertEqual(monitor.state, .live)
        await fixture.setMode(2)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .signInRequired)
        XCTAssertFalse(monitor.canResume)
        XCTAssertEqual(monitor.menuTitle, "LTE · Sign in")
        let before = await fixture.count()
        await monitor.refresh()
        let after = await fixture.count()
        XCTAssertEqual(before, after)
        await monitor.shutdown()
    }
    @MainActor func testConnectionAndTrialStartsAreReservedBeforeSuspending() async throws {
        let fixture = ConnectionFixture()
        let monitor = Monitor(ephemeral: true, clientFactory: { _, _ in fixture })
        let first = Task { await monitor.connect(password: "synthetic", persistSettings: false) }
        await Task.yield()
        await monitor.startDemo()
        await monitor.pause()
        await first.value
        XCTAssertFalse(monitor.demo)
        XCTAssertEqual(monitor.state, .live)
        XCTAssertNotNil(monitor.currentSession)
        XCTAssertEqual(monitor.sessions.count, 1)
        let one = Task { await monitor.beginTrial() }
        let two = Task { await monitor.beginTrial() }
        await one.value; await two.value
        XCTAssertEqual(monitor.trials.count, 1)
        await monitor.pause()
        XCTAssertNil(monitor.activeTrial)
        XCTAssertEqual(monitor.state, .paused)
        await monitor.shutdown()
    }

}
