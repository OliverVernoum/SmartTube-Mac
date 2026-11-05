import Foundation

/// Data scraped from https://www.youtube.com/tv and its scripts:
/// visitorData, player js (signature timestamp + challenge code), OAuth client id/secret.
actor AppInfo {
    static let shared = AppInfo()

    struct TVPage {
        let visitorData: String?
        let playerURL: URL?
        let baseJSURL: URL?
        let fetched: Date
    }

    struct PlayerJS {
        let url: URL
        let code: String
        let signatureTimestamp: Int?
    }

    private var pages: [String: TVPage] = [:]       // keyed by user agent
    private var players: [URL: PlayerJS] = [:]
    private var oauth: (id: String, secret: String)?

    private let ttl: TimeInterval = 6 * 3600

    func tvPage(userAgent: String) async throws -> TVPage {
        if let p = pages[userAgent], Date().timeIntervalSince(p.fetched) < ttl { return p }
        let html = try await HTTP.shared.text(URL(string: "https://www.youtube.com/tv")!, headers: ["User-Agent": userAgent])
        let visitor = html.firstMatch(#""visitorData":"(.*?)""#)?.replacingOccurrences(of: "\\u003d", with: "=")
        var player = html.firstMatch(#""player_url":"(.*?)""#)
        if player == nil { player = html.firstMatch(#"(/s/player/[A-Za-z0-9_\-]+/[^"']*?\.js)"#) }
        let base = html.firstMatch(#"id="base-js" src="(.*?)""#)
            ?? html.firstMatch(#"\.src = '(.*?m=base)'"#)
            ?? html.firstMatch(#"\.src = '(.*?)'; .\.id = 'base-js'"#)
        let page = TVPage(
            visitorData: visitor.map { $0.removingPercentEncoding ?? $0 },
            playerURL: player.flatMap { Self.absolute($0.replacingOccurrences(of: "\\/", with: "/")) },
            baseJSURL: base.flatMap { Self.absolute($0) },
            fetched: Date())
        pages[userAgent] = page
        return page
    }

    func visitorData() async -> String? {
        try? await tvPage(userAgent: InnerTubeClient.tv.userAgent).visitorData
    }

    func playerJS(for client: InnerTubeClient) async throws -> PlayerJS {
        let page = try await tvPage(userAgent: client.userAgent)
        guard let url = page.playerURL else { throw APIError.parse("player url not found") }
        if let p = players[url] { return p }
        if let cached = DiskCache.load("player-\(url.path)"), let code = String(data: cached, encoding: .utf8) {
            let p = PlayerJS(url: url, code: code, signatureTimestamp: code.firstMatch(#"signatureTimestamp:(\d+)"#).flatMap { Int($0) })
            players[url] = p
            return p
        }
        let code = try await HTTP.shared.text(url, headers: ["User-Agent": client.userAgent])
        let sts = code.firstMatch(#"signatureTimestamp:(\d+)"#).flatMap { Int($0) }
            ?? code.firstMatch(#"sts\s*:\s*(\d{5})"#).flatMap { Int($0) }
        let p = PlayerJS(url: url, code: code, signatureTimestamp: sts)
        players[url] = p
        DiskCache.store("player-\(url.path)", Data(code.utf8))
        return p
    }

    /// OAuth client credentials of the TV app (same approach as SmartTube's ClientData).
    func oauthClient() async throws -> (id: String, secret: String) {
        if let oauth { return oauth }
        let page = try await tvPage(userAgent: InnerTubeClient.tv.userAgent)
        guard let base = page.baseJSURL else { throw APIError.parse("base js not found") }
        let js = try await HTTP.shared.text(base, headers: ["User-Agent": InnerTubeClient.tv.userAgent])
        guard let id = js.firstMatch(#"clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"\w+""#),
              let secret = js.firstMatch(#"clientId:"[-\w]+\.apps\.googleusercontent\.com",\n?[$\w]+:"(\w+)""#) else {
            throw APIError.parse("OAuth client id not found")
        }
        oauth = (id, secret)
        return (id, secret)
    }

    func invalidate() {
        pages.removeAll()
        players.removeAll()
    }

    private static func absolute(_ s: String) -> URL? {
        if s.hasPrefix("http") { return URL(string: s) }
        if s.hasPrefix("//") { return URL(string: "https:" + s) }
        return URL(string: "https://www.youtube.com" + (s.hasPrefix("/") ? s : "/" + s))
    }
}

/// Simple file cache under ~/Library/Caches/SmartTube.
enum DiskCache {
    static var dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SmartTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static func safe(_ key: String) -> String {
        key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    static func load(_ key: String, maxAge: TimeInterval = 7 * 86400) -> Data? {
        let url = dir.appendingPathComponent(safe(key))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date, Date().timeIntervalSince(date) < maxAge else { return nil }
        return try? Data(contentsOf: url)
    }

    static func store(_ key: String, _ data: Data) {
        try? data.write(to: dir.appendingPathComponent(safe(key)), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}
