import Foundation

enum APIError: LocalizedError {
    case http(Int, String)
    case parse(String)
    case unplayable(String)
    case notSignedIn
    case other(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parse(let s): return "Parse error: \(s)"
        case .unplayable(let s): return s
        case .notSignedIn: return "Sign in required"
        case .other(let s): return s
        }
    }
}

/// Thin async wrapper around URLSession.
final class HTTP {
    static let shared = HTTP()

    let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    func data(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.other("No HTTP response") }
        return (data, http)
    }

    func text(_ url: URL, headers: [String: String] = [:]) async throws -> String {
        let (d, r) = try await data(url, headers: headers)
        guard (200..<300).contains(r.statusCode) else { throw APIError.http(r.statusCode, String(decoding: d, as: UTF8.self)) }
        return String(decoding: d, as: UTF8.self)
    }

    func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> JSON {
        let (d, r) = try await data(url, method: method, headers: headers, body: body)
        guard (200..<300).contains(r.statusCode) else { throw APIError.http(r.statusCode, String(decoding: d, as: UTF8.self)) }
        return try JSON(data: d)
    }

    /// Fetches an inclusive byte range.
    func range(_ url: URL, from: Int64, to: Int64, headers: [String: String] = [:]) async throws -> Data {
        var h = headers
        h["Range"] = "bytes=\(from)-\(to)"
        let (d, r) = try await data(url, headers: h)
        guard (200..<300).contains(r.statusCode) else { throw APIError.http(r.statusCode, "range request failed") }
        return d
    }
}

extension String {
    func firstMatch(_ pattern: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    var urlQueryEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}

extension URL {
    func settingQuery(_ name: String, _ value: String?) -> URL {
        guard var c = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        var items = c.percentEncodedQueryItems ?? []
        items.removeAll { $0.name == name }
        if let value { items.append(URLQueryItem(name: name, value: value.urlQueryEncoded)) }
        c.percentEncodedQueryItems = items
        return c.url ?? self
    }

    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

func parseQueryString(_ s: String) -> [String: String] {
    var out: [String: String] = [:]
    for pair in s.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
        guard let k = kv.first else { continue }
        let v = kv.count > 1 ? kv[1] : ""
        out[k.removingPercentEncoding ?? k] = v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? v
    }
    return out
}
