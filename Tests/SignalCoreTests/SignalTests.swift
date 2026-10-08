import XCTest
@testable import SignalCore

final class SignalTests: XCTestCase {
    func fixture(rssi: String = "24", sinr: String = "10") -> String {
        "<table><tr><td>Status</td><td>Connected</td></tr><tr><td>Network Type</td><td>3 UK 4G <img src='signal.png'></td></tr><tr><td>SINR</td><td>\(sinr)</td></tr><tr><td>RSRQ</td><td>-10</td></tr><tr><td>RSRP</td><td>-96</td></tr><tr><td>RSSI</td><td>\(rssi)</td></tr><tr><td>Band</td><td>3</td></tr><tr><td>Cell ID</td><td>ABC123</td></tr><tr><td>IMSI</td><td>DO-NOT-RETAIN</td></tr></table>"
    }
    func testScreenshotShapedTable() throws {
        let sample = try RouterHTML.parse(fixture())
        XCTAssertEqual(sample.values.compactMap { $0 }, [10,-10,-96,24])
        XCTAssertEqual(sample.rssiUnit, "raw index"); XCTAssertEqual(sample.band, "3")
        XCTAssertEqual(sample.carrier, "3 UK 4G"); XCTAssertTrue(sample.connected)
    }
    func testUnitsDecimalsAndNegativeRSSI() throws {
        let sample = try RouterHTML.parse(fixture(rssi: "-65 dBm", sinr: "12.5 dB"))
        XCTAssertEqual(sample.sinr, 12.5); XCTAssertEqual(sample.rssiUnit, "dBm")
    }
    func testUnknownDoesNotBecomeZero() throws {
        let sample = try RouterHTML.parse(fixture(rssi: "99", sinr: "N/A"))
        XCTAssertNil(sample.sinr); XCTAssertNil(sample.rssi)
    }
    func testOutOfRangeAndEmbeddedNumbersRejected() throws {
        let sample = try RouterHTML.parse(fixture(rssi: "24 unknown 55", sinr: "999"))
        XCTAssertNil(sample.sinr); XCTAssertNil(sample.rssi)
    }
    func testLoginAndEmptyPageRejected() {
        XCTAssertThrowsError(try RouterHTML.parse("<input name='luci_password' value=''>"))
        XCTAssertThrowsError(try RouterHTML.parse("<table><tr><td>SINR</td><td>—</td></tr></table>"))
    }
    func testAttributeOrderAndCase() {
        XCTAssertEqual(RouterHTML.fields("<INPUT value='admin' type='hidden' NAME='luci_username'>")["luci_username"], "admin")
    }
    func testHashedLoginProtocolAndEncoding() throws {
        let html = "<input name='luci_password'><input name='salt' value='test-salt'><input name='token' value='test-token'><input name='luci_username' value='admin'><input name='_csrf' value='test-csrf'>"
        let body = String(data: try RouterProtocol.loginBody(html: html, password: "fixture-only&+"), encoding: .utf8)!
        XCTAssertTrue(body.contains("luci_password=" + RouterProtocol.hash(RouterProtocol.hash("fixture-only&+test-salt") + "test-token")))
        XCTAssertFalse(body.contains("fixture-only")); XCTAssertTrue(body.contains("luci_username=admin"))
    }
    func testLegacyFormEncoding() throws {
        let body = String(data: try RouterProtocol.loginBody(html: "<input name='luci_password'>", password: "a&b+c"), encoding: .utf8)!
        XCTAssertTrue(body.contains("luci_password=a%26b%2Bc"))
    }
    func testEmptyChallengeFieldsStillUseHashWhenPresent() throws {
        let html = "<input name='luci_password'><input name='salt' value=''><input name='token' value=''>"
        let body = String(data: try RouterProtocol.loginBody(html: html, password: "fixture-only"), encoding: .utf8)!
        XCTAssertTrue(body.contains("luci_password=" + RouterProtocol.hash(RouterProtocol.hash("fixture-only"))))
    }
    func testLocalAddressRestriction() throws {
        for host in ["192.168.10.1","10.0.0.1","172.16.1.1","172.31.1.1"] { XCTAssertNotNil(try RouterProtocol.baseURL(host)) }
        for host in ["example.com","127.0.0.1","169.254.169.254","8.8.8.8","172.32.0.1","192.168.256.1","192.168.10.1/evil","192.168.10.1@evil.com","192.168.10.1:80","010.0.0.1","192.168.010.1"] { XCTAssertThrowsError(try RouterProtocol.baseURL(host)) }
    }
    func testOversizedResponseRejected() { XCTAssertThrowsError(try RouterHTML.parse(String(repeating: "x", count: 2_000_001))) }
    func testResponsiveCudyRowsDoNotConcatenateDesktopAndMobileValues() throws {
        let html = "<table>" + [("SINR","10"),("RSRQ","-10"),("RSRP","-96"),("RSSI","24")].map { key,value in
            "<tr><td><span class='hidden-xs'>\(key)</span><p class='visible-xs'>\(key)</p></td><td><span class='hidden-xs'>\(value)</span><p class='visible-xs'>\(value)</p></td></tr>"
        }.joined() + "</table>"
        XCTAssertEqual(try RouterHTML.parse(html).values.compactMap { $0 }, [10,-10,-96,24])
    }
    func testPrefersVisibleMobileValueOverDesktopDuplicate() throws {
        let html = "<table><tr><td>SINR</td><td><span class='hidden-xs'>3</span><p class='visible-xs text-info'>12</p></td></tr></table>"
        XCTAssertEqual(try RouterHTML.parse(html).sinr, 12)
    }
    func testScriptsAreNotReadings() {
        let html = "<script>\nvar template = '<table><tr><td>SINR</td><td>10</td></tr></table>';\n</script>"
        XCTAssertThrowsError(try RouterHTML.parse(html))
        XCTAssertTrue(RouterHTML.structureSummary(html).contains("metric labels: none"))
    }
    func testDiagnosticsContainNoPrivateValues() {
        let html = fixture() + "<div>COOKIE-FIXTURE SECRET-FIXTURE</div>"
        let summary = RouterHTML.structureSummary(html)
        XCTAssertTrue(summary.contains("SINR, RSRQ, RSRP, RSSI"))
        for value in ["DO-NOT-RETAIN", "COOKIE-FIXTURE", "SECRET-FIXTURE", "ABC123"] { XCTAssertFalse(summary.contains(value)) }
    }
}
