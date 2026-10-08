import XCTest
import Foundation
import SignalCore
@testable import BiQuadMonitor

private final class RouterFixtureProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/html"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

final class RouterClientTests: XCTestCase {
    func fixture() throws -> String {
        let url = Bundle.module.url(forResource: "lt500-detailed-status", withExtension: "html", subdirectory: "Fixtures")!
        return try String(contentsOf: url)
    }
    @MainActor func makeClient() throws -> RouterClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterFixtureProtocol.self]
        return try RouterClient(host: "192.168.10.1", secure: false, configuration: config)
    }
    func testRealLT500MetricRows() throws {
        // Only the four signal rows are retained; no login material or SIM identifiers.
        let sample = try RouterHTML.parse(fixture())
        XCTAssertEqual(sample.values.compactMap { $0 }, [10, -10, -96, 23])
        XCTAssertEqual(sample.rssiUnit, "raw index")
    }
    @MainActor func testPollReadsDetailedFragmentInsteadOfEmptyPageShell() async throws {
        let detail = try fixture()
        var requestedPaths: [String] = []
        RouterFixtureProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let url = request.url!
            requestedPaths.append(url.path)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
            if url.path == "/cgi-bin/luci/admin/network/gcom/status",
               query.contains(URLQueryItem(name: "detail", value: "1")),
               query.contains(URLQueryItem(name: "iface", value: "4g")) {
                return (200, detail)
            }
            // Actual LT500 parent page has tabs and a JavaScript loader, with no readings.
            return (200, "<div id='tab-status-1'></div><script>cbi_xhr_load('#tab-status-1', 'poll', '/cgi-bin/luci/admin/network/gcom/status', 'detail=1&iface=4g');</script>")
        }
        let client = try makeClient()
        defer { client.close(); RouterFixtureProtocol.handler = nil }
        let first = try await client.poll()
        let second = try await client.poll()
        XCTAssertEqual(first.values.compactMap { $0 }, [10, -10, -96, 23])
        XCTAssertEqual(second.values, first.values)
        XCTAssertEqual(requestedPaths, Array(repeating: "/cgi-bin/luci/admin/network/gcom/status", count: 2))
    }
    @MainActor func testExpiredSessionIsReportedAsLoginError() async throws {
        RouterFixtureProtocol.handler = { _ in (403, "<input name='luci_password' value=''>") }
        let client = try makeClient()
        defer { client.close(); RouterFixtureProtocol.handler = nil }
        do { _ = try await client.poll(); XCTFail("Expired session must fail") }
        catch MonitorError.login { }
        catch { XCTFail("Expected login error, received \(error)") }
    }
    @MainActor func testMalformedStatusDoesNotBecomeFakeSignalValues() async throws {
        RouterFixtureProtocol.handler = { _ in (200, "<div>PRIVATE-FIXTURE</div>") }
        let client = try makeClient()
        defer { client.close(); RouterFixtureProtocol.handler = nil }
        do { _ = try await client.poll(); XCTFail("Empty readings must fail") }
        catch MonitorError.cellularFormat(let details) {
            XCTAssertTrue(details.contains("Rows: 0"))
            XCTAssertFalse(details.contains("PRIVATE-FIXTURE"))
        }
    }
}
