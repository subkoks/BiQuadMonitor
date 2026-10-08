import XCTest
import CoreGraphics
@testable import SignalCore

final class WindowPlacementTests: XCTestCase {
    func testWindowAboveScreenIsMovedBelowMenuBar() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 830)
        let fitted = WindowPlacement.fit(CGRect(x: 1100, y: 700, width: 460, height: 500), inside: screen)
        XCTAssertTrue(screen.contains(fitted)); XCTAssertEqual(fitted.maxY, screen.maxY)
    }
    func testOversizedWindowFitsSmallScreen() {
        let screen = CGRect(x: 0, y: 25, width: 640, height: 420)
        let fitted = WindowPlacement.fit(CGRect(x: -50, y: -300, width: 800, height: 1000), inside: screen)
        XCTAssertEqual(fitted, screen)
    }
    func testSecondDisplayWithNegativeOrigin() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1000)
        let fitted = WindowPlacement.fit(CGRect(x: -2200, y: 780, width: 460, height: 500), inside: screen)
        XCTAssertTrue(screen.contains(fitted))
    }
    func testAlreadyVisiblePositionIsPreserved() {
        let frame = CGRect(x: 20, y: 80, width: 420, height: 600)
        XCTAssertEqual(WindowPlacement.fit(frame, inside: CGRect(x: 0, y: 40, width: 1440, height: 830)), frame)
    }
    func testDisconnectedDisplayPositionIsRecovered() {
        let screen = CGRect(x: 0, y: 40, width: 1440, height: 830)
        XCTAssertTrue(screen.contains(WindowPlacement.fit(CGRect(x: 3000, y: 2000, width: 420, height: 650), inside: screen)))
    }
    func testTLSFailureHasSpecificMessage() {
        let error = MonitorError.network(NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-DETAILS"]))
        XCTAssertTrue(error.localizedDescription.contains("HTTPS certificate"))
        XCTAssertFalse(error.localizedDescription.contains("PRIVATE-DETAILS"))
    }
    func testTimeoutIsNotReportedAsCertificateFailure() {
        XCTAssertTrue(MonitorError.network(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)).localizedDescription.contains("timed out"))
    }
    func testUnavailableServiceHasSpecificMessage() {
        XCTAssertTrue(MonitorError.network(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)).localizedDescription.contains("HTTP / HTTPS"))
    }
}
