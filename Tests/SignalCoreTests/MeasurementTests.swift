import XCTest
@testable import SignalCore

final class MeasurementTests: XCTestCase {
    func sample(_ time: Double = 0, sinr: Double? = 8, band: String = "3", cell: String = "DEMO-A") -> SignalSample {
        SignalSample(date: Date(timeIntervalSince1970: time), sinr: sinr, rsrq: -9, rsrp: -96, rssi: 23, band: band, cell: cell)
    }
    func testFullMenuAndUnavailableStates() {
        XCTAssertEqual(DisplayFormat.menu(sample: sample(), state: .live), "LTE BAND 3 | SINR 8 | RSRQ −9 | RSRP −96 | RSSI 23")
        XCTAssertEqual(DisplayFormat.menu(sample: sample(), state: .stale), "LTE · Stale")
        XCTAssertEqual(DisplayFormat.menu(sample: sample(), state: .noService), "LTE · No cellular service")
        XCTAssertTrue(DisplayFormat.menu(sample: sample(), state: .demo).hasPrefix("DEMO BAND"))
        XCTAssertEqual(DisplayFormat.number(-0.001), "0")
        XCTAssertEqual(DisplayFormat.number(.nan), "—")
    }
    func testChartDoesNotBridgeMissingReadingsOrTimeGaps() {
        let id = UUID()
        let records = [sample(0), sample(5, sinr: nil), sample(10), sample(60), sample(65, band: "20")].map { SignalRecord(sessionID: id, sample: $0) }
        let points = ChartData.points(records, metric: .sinr)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(Set(points.map(\.series)).count, 4)
    }
    func testComparisonRequiresKnownMatchingContext() {
        let id = UUID()
        let a = [SignalRecord(sessionID: id, sample: sample())]
        XCTAssertTrue(TrialAnalysis.comparable(a, a))
        XCTAssertFalse(TrialAnalysis.comparable(a, [SignalRecord(sessionID: id, sample: sample(band: "20"))]))
        XCTAssertFalse(TrialAnalysis.comparable(a, [SignalRecord(sessionID: id, sample: sample(cell: "—"))]))
        XCTAssertFalse(TrialAnalysis.comparable([], []))
    }
    func testQuantilesAndCoverage() {
        let distribution = Distribution([0, 10, 20, 30, 40])!
        XCTAssertEqual(distribution.median, 20); XCTAssertEqual(distribution.p10, 4); XCTAssertEqual(distribution.p90, 36)
        XCTAssertEqual(distribution.iqr, 20)
        XCTAssertNil(Distribution([.nan, .infinity]))
        let records = [SignalRecord(sessionID: UUID(), sample: sample())]
        XCTAssertEqual(TrialAnalysis.coverage(records, duration: 10, interval: 5), 0.5)
    }
    func testDisconnectedStatusIsNotParserFailure() throws {
        let sample = try RouterHTML.parse("<table><tr><td>Status</td><td>Disconnected</td></tr><tr><td>SINR</td><td>N/A</td></tr></table>")
        XCTAssertFalse(sample.connected); XCTAssertTrue(sample.values.allSatisfy { $0 == nil })
    }
    func testUnlabelledNegativeRSSIIsNotGuessedAsDBm() throws {
        let sample = try RouterHTML.parse("<table><tr><td>SINR</td><td>8</td></tr><tr><td>RSSI</td><td>-65</td></tr></table>")
        XCTAssertNil(sample.rssi)
    }
    func testDisplayReductionPreservesSpikeAndGap() {
        let id = UUID()
        var records: [SignalRecord] = []
        for index in 0..<2000 {
            let reading = sample(Double(index * 5), sinr: index == 400 ? 29 : 8)
            records.append(SignalRecord(sessionID: id, sample: reading, segment: index < 1000 ? 0 : 1))
        }
        let reduced = ChartData.displayPoints(records, metric: .sinr, budget: 200)
        XCTAssertLessThanOrEqual(reduced.count, 200)
        XCTAssertEqual(reduced.map(\.value).max(), 29)
        XCTAssertEqual(Set(reduced.map(\.series)).count, 2)
        XCTAssertEqual(reduced.last?.date, records.last?.sample.date)
    }

    func testRSSIChartNeverPutsRawIndicesOnDBmAxisOrBridgesUnitGaps() {
        let id = UUID()
        let values = [(23.0, RSSIUnit.rawIndex), (-65.0, .dBm), (24.0, .rawIndex)]
        let records = values.enumerated().map { index, pair in
            SignalRecord(sessionID: id, sample: SignalSample(date: Date(timeIntervalSince1970: Double(index * 5)), sinr: 8, rsrq: -9, rsrp: -96, rssi: pair.0, rssiUnits: pair.1))
        }
        let raw = ChartData.displayPoints(records, metric: .rssi)
        XCTAssertEqual(raw.map(\.value), [23, 24])
        XCTAssertEqual(Set(raw.map(\.series)).count, 2)
        let dbm = ChartData.displayPoints(Array(records.prefix(2)), metric: .rssi)
        XCTAssertEqual(dbm.map(\.value), [-65])
    }

}
