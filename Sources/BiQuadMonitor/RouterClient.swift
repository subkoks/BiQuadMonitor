import Foundation
import Security
import SignalCore

final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    let base: URL
    init(base: URL) { self.base = base }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward a login body or cookies to a different origin or settings action.
        guard let url = request.url, url.host == base.host, url.scheme == base.scheme, url.port == base.port,
              request.httpMethod == "GET", ["/cgi-bin/luci", "/cgi-bin/luci/", "/cgi-bin/luci/admin/panel", "/cgi-bin/luci/admin/network/gcom"].contains(url.path), url.query == nil || url.query == "iface=4g" else { completionHandler(nil); return }
        completionHandler(request)
    }
}

protocol RouterConnection: Sendable {
    func login(password: String) async throws -> SignalSample
    func poll() async throws -> SignalSample
    func close()
}

actor RouterClient: RouterConnection {
    private let base: URL
    private let session: URLSession
    private var responseSummary = ""
    init(host: String, secure: Bool, configuration: URLSessionConfiguration = .ephemeral) throws {
        base = try RouterProtocol.baseURL(host, secure: secure)
        let config = configuration
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config, delegate: RedirectGuard(base: base), delegateQueue: nil)
    }
    nonisolated func close() { session.invalidateAndCancel() }
    func probePublicLogin() async throws {
        let html = try await request("/cgi-bin/luci/")
        print("Public login form: \(RouterHTML.isLogin(html) ? "present" : "absent"); \(RouterHTML.structureSummary(html))")
    }
    private func request(_ path: String, body: Data? = nil) async throws -> String {
        let url = URL(string: path, relativeTo: base)!.absoluteURL
        var request = URLRequest(url: url)
        request.setValue("BiQuadMonitor/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"; request.httpBody = body
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue(base.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue(base.absoluteString + "/cgi-bin/luci/", forHTTPHeaderField: "Referer")
        }
        let data: Data; let response: URLResponse
        do {
            let (bytes, received) = try await session.bytes(for: request)
            response = received
            guard response.expectedContentLength <= 2_000_000 else { bytes.task.cancel(); throw MonitorError.format }
            var buffer = Data()
            buffer.reserveCapacity(min(64_000, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard buffer.count < 2_000_000 else { bytes.task.cancel(); throw MonitorError.format }
                buffer.append(byte)
            }
            data = buffer
        } catch let error as MonitorError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MonitorError.network(error) }
        guard let http = response as? HTTPURLResponse else { throw MonitorError.transport }
        guard data.count <= 2_000_000 else { throw MonitorError.format }
        // LuCI serves its public login form with HTTP 403.
        guard (200...299).contains(http.statusCode) || http.statusCode == 403 else {
            if (300...399).contains(http.statusCode) { throw MonitorError.redirect }
            throw MonitorError.serverStatus(http.statusCode)
        }
        guard let text = String(data: data, encoding: .utf8) else { throw MonitorError.format }
        let kind = (http.mimeType ?? "").lowercased()
        let type = kind.contains("html") ? "HTML" : (kind.contains("json") ? "JSON" : "other")
        let scriptLabels = ["SINR", "RSRQ", "RSRP", "RSSI"].filter { text.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
        responseSummary = "HTTP \(http.statusCode), \(type); raw metric labels: \(scriptLabels.isEmpty ? "none" : scriptLabels.joined(separator: ", "))."
        if http.statusCode == 403 && !RouterHTML.isLogin(text) { throw MonitorError.login }
        return text
    }
    func login(password: String) async throws -> SignalSample {
        let html = try await request("/cgi-bin/luci/")
        if RouterHTML.isLogin(html) {
            let action = RouterHTML.matches("<form\\b[^>]*>", html).compactMap { RouterHTML.attributes($0[0])["action"] }.first ?? "/cgi-bin/luci/"
            guard action == "/cgi-bin/luci/" || action == "/cgi-bin/luci" || action.isEmpty else { throw MonitorError.loginForm }
            let result = try await request("/cgi-bin/luci/", body: RouterProtocol.loginBody(html: html, password: password))
            if RouterHTML.isLogin(result) { throw MonitorError.login }
            let cellularURL = URL(string: "/cgi-bin/luci/admin/network/gcom", relativeTo: base)!.absoluteURL
            let authPresent = session.configuration.httpCookieStorage?.cookies(for: cellularURL)?.contains(where: { ["sysauth", "sysauth_http", "sysauth_https"].contains($0.name) }) ?? false
            guard authPresent else { throw MonitorError.session(responseSummary + " No usable router session cookie.") }
        }
        return try await poll()
    }
    func poll() async throws -> SignalSample {
        // The parent gcom page is only a tab shell. LT500 2.4.16 loads this
        // fragment with cbi_xhr_load; detail=1 includes the four radio metrics.
        let html = try await request("/cgi-bin/luci/admin/network/gcom/status?detail=1&iface=4g")
        do { return try RouterHTML.parse(html) }
        catch MonitorError.format { throw MonitorError.cellularFormat(responseSummary + " " + RouterHTML.structureSummary(html)) }
    }
}

enum PasswordStore {
    static func query(_ account: String) -> [String:Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "local.blackterminal.BiQuadMonitor", kSecAttrAccount as String: account]
    }
    static func read(_ account: String) -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ password: String, account: String) throws {
        let q = query(account), data = Data(password.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StoreError.failed }
        } else if status != errSecSuccess { throw StoreError.failed }
    }
    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
    enum StoreError: LocalizedError { case failed; var errorDescription: String? { "Could not save the password in Keychain. The current session can still run." } }
}
