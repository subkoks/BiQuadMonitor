import Foundation
import CryptoKit

public enum MonitorError: LocalizedError {
    case host, login, format, transport, redirect, loginForm, certificate, timeout, unreachable, localPermission
    case serverStatus(Int)
    case cellularFormat(String)
    case session(String)
    public var errorDescription: String? {
        switch self {
        case .host: return "Enter a private local IPv4 address, such as 192.168.10.1."
        case .login: return "Sign-in required or rejected. Check the router password in Settings."
        case .format: return "No cellular readings found. This firmware response is not supported yet."
        case .transport: return "Router did not respond. Check your local network connection."
        case .redirect: return "Router attempted an unsupported redirect; connection stopped."
        case .loginForm: return "The router returned an unsupported sign-in form. No password was submitted."
        case .cellularFormat(let details): return "Cellular page could not be read. " + details
        case .session(let details): return "Router sign-in session was not established. " + details
        case .certificate: return "HTTPS certificate is not trusted or TLS could not be established. Select the same HTTP / HTTPS service used by your browser, or configure a trusted certificate."
        case .timeout: return "Router connection timed out. Check the IP and local network connection."
        case .unreachable: return "Cannot reach the selected router service. Check the IP and HTTP / HTTPS selection."
        case .localPermission: return "Network access is unavailable. Check your connection and macOS System Settings → Privacy & Security → Local Network for BiQuad Monitor."
        case .serverStatus(let status): return "Router returned HTTP \(status). The connection reached the router, but the request was rejected."
        }
    }
    public static func network(_ error: Error) -> MonitorError {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .transport }
        switch ns.code {
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorSecureConnectionFailed: return .certificate
        case NSURLErrorTimedOut: return .timeout
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return .unreachable
        case NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed: return .localPermission
        default: return .transport
        }
    }
}

public struct SignalSample: Equatable, Codable, Sendable {
    public let date: Date
    public let sinr: Double?
    public let rsrq: Double?
    public let rsrp: Double?
    public let rssi: Double?
    public let band: String
    public let cell: String
    public let carrier: String
    public let connected: Bool
    public let rssiUnits: RSSIUnit
    public let details: [String: String]
    public init(date: Date = Date(), sinr: Double?, rsrq: Double?, rsrp: Double?, rssi: Double?, band: String = "—", cell: String = "—", carrier: String = "—", connected: Bool = true, rssiUnits: RSSIUnit = .rawIndex, details: [String: String] = [:]) {
        self.date = date; self.sinr = sinr; self.rsrq = rsrq; self.rsrp = rsrp; self.rssi = rssi
        self.band = band; self.cell = cell; self.carrier = carrier; self.connected = connected
        self.rssiUnits = rssiUnits; self.details = details
    }
    public var values: [Double?] { [sinr, rsrq, rsrp, rssi] }
    public var rssiUnit: String { rssi == nil ? "" : rssiUnits.rawValue }
}

public enum RouterHTML {
    public static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { result in
            (0..<result.numberOfRanges).map { result.range(at: $0).location == NSNotFound ? "" : ns.substring(with: result.range(at: $0)) }
        }
    }
    public static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (a,b) in [("&nbsp;"," "),("&#160;"," "),("&amp;","&"),("&minus;","-"),("−","-"),("&quot;","\""),("&#39;","'")] { result = result.replacingOccurrences(of: a, with: b) }
        return result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func attributes(_ tag: String) -> [String:String] {
        var out: [String:String] = [:]
        for m in matches("([a-z_][a-z0-9_-]*)\\s*=\\s*([\"'])(.*?)\\2", tag) { out[m[1].lowercased()] = m[3] }
        return out
    }
    public static func fields(_ html: String) -> [String:String] {
        var out: [String:String] = [:]
        for m in matches("<input\\b[^>]*>", html) {
            let a = attributes(m[0]); if let name = a["name"] { out[name] = a["value"] ?? "" }
        }
        return out
    }
    public static func isLogin(_ html: String) -> Bool { fields(html)["luci_password"] != nil }
    public static func visibleHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "(?is)<(script|style)\\b[^>]*>.*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
    }
    public static func cellText(_ cell: String) -> String {
        // Bootstrap status tables may repeat values for desktop and phone layouts.
        // Prefer the phone paragraph instead of concatenating both copies.
        for tag in ["p", "span"] {
            let candidates = matches("<\(tag)\\b([^>]*)>(.*?)</\(tag)>", cell)
            if let preferred = candidates.first(where: { (attributes($0[1])["class"] ?? "").split(separator: " ").contains("visible-xs") }) {
                return clean(preferred[2])
            }
        }
        for tag in ["p", "span"] {
            if let first = matches("<\(tag)\\b[^>]*>(.*?)</\(tag)>", cell).first, !clean(first[1]).isEmpty { return clean(first[1]) }
        }
        return clean(cell)
    }
    public static func structureSummary(_ html: String) -> String {
        // Counts and fixed metric names only: never raw HTML, cookies or SIM identifiers.
        let content = visibleHTML(html)
        let labels = ["SINR", "RSRQ", "RSRP", "RSSI"].filter { content.range(of: "\\b\($0)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
        let rows = matches("<tr\\b", content).count
        let paragraphs = matches("<p\\b[^>]*class=[\"'][^\"']*visible-xs", content).count
        return "Rows: \(rows); mobile fields: \(paragraphs); metric labels: \(labels.isEmpty ? "none" : labels.joined(separator: ", "))."
    }
    public static func parse(_ html: String, date: Date = Date()) throws -> SignalSample {
        guard html.utf8.count <= 2_000_000 else { throw MonitorError.format }
        if isLogin(html) { throw MonitorError.login }
        var table: [String:String] = [:]
        let content = visibleHTML(html)
        for row in matches("<tr\\b[^>]*>(.*?)</tr>", content) {
            let cells = matches("<t[dh]\\b[^>]*>(.*?)</t[dh]>", row[1]).map { cellText($0[1]) }.filter { !$0.isEmpty }
            if cells.count >= 2 { table[cells[0].uppercased()] = cells[1] }
        }
        func number(_ key: String, range: ClosedRange<Double>) -> Double? {
            guard let text = table[key], let m = matches("^\\s*([+-]?[0-9]+(?:\\.[0-9]+)?)(?:\\s*(?:dBm|dB))?\\s*$", text).first,
                  let value = Double(m[1]), range.contains(value) else { return nil }
            if key == "RSSI" && value == 99 { return nil }
            return value
        }
        // LT500 index values are 0...31; dBm requires an explicit unit from the page.
        let rssiUnits: RSSIUnit = table["RSSI"]?.lowercased().contains("dbm") == true ? .dBm : .rawIndex
        let safeKeys = ["PCID", "MCC", "MNC", "MODE", "UL BANDWIDTH", "DL BANDWIDTH", "CONNECTED TIME", "UPLOAD / DOWNLOAD"]
        let details = table.filter { safeKeys.contains($0.key) && $0.value.count <= 160 }
        let status = table["STATUS"]?.lowercased()
        let sample = SignalSample(date: date, sinr: number("SINR", range: -40...60), rsrq: number("RSRQ", range: -40...0), rsrp: number("RSRP", range: -160 ... -20), rssi: number("RSSI", range: rssiUnits == .dBm ? -150...0 : 0...31), band: String((table["BAND"] ?? "—").prefix(40)), cell: String((table["CELL ID"] ?? "—").prefix(80)), carrier: String((table["NETWORK TYPE"] ?? "—").prefix(120)), connected: status == "connected", rssiUnits: rssiUnits, details: details)
        guard sample.values.contains(where: { $0 != nil }) || status == "disconnected" else { throw MonitorError.format }
        return sample
    }
}

public enum RouterProtocol {
    public static func baseURL(_ host: String, secure: Bool = false) throws -> URL {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } && ($0.count == 1 || !$0.hasPrefix("0")) }),
              let a = Int(parts[0]), let b = Int(parts[1]), parts.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }),
              a == 10 || (a == 192 && b == 168) || (a == 172 && (16...31).contains(b)),
              let url = URL(string: "\(secure ? "https" : "http")://\(host)") else { throw MonitorError.host }
        return url
    }
    public static func hash(_ string: String) -> String { SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func loginBody(html: String, password: String) throws -> Data {
        let fields = RouterHTML.fields(html)
        guard fields["luci_password"] != nil else { throw MonitorError.format }
        let salt = fields["salt"] ?? "", token = fields["token"] ?? ""
        var encodedPassword = password
        if fields["salt"] != nil { encodedPassword = hash(password + salt); if fields["token"] != nil { encodedPassword = hash(encodedPassword + token) } }
        var values = ["luci_username": fields["luci_username"] ?? "admin", "luci_password": encodedPassword, "luci_language": "en", "zonename": TimeZone.current.identifier, "timeclock": String(Int(Date().timeIntervalSince1970))]
        for name in ["salt", "token", "_csrf"] { if let value = fields[name] { values[name] = value } }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.keys.sorted().map { key in "\(key)=\(values[key]!.addingPercentEncoding(withAllowedCharacters: allowed)!)" }.joined(separator: "&").utf8)
    }
}
