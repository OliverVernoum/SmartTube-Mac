import Foundation

/// InnerTube (youtubei/v1) request builder, equivalent of SmartTube's QueryBuilder + Retrofit APIs.
enum InnerTube {
    static let base = "https://www.youtube.com/youtubei/v1/"

    static func context(_ client: InnerTubeClient, browse: Bool, visitorData: String?, clickTracking: String? = nil) -> [String: Any] {
        let s = Settings.shared
        var c: [String: Any] = [
            "clientName": client.name,
            "clientVersion": client.version,
            "clientScreen": client.screen,
            "userAgent": client.userAgent,
            "hl": s.language,
            "gl": s.country,
            "acceptLanguage": s.language,
            "acceptRegion": s.country,
            "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60
        ]
        for (k, v) in client.extraClient { c[k] = v }
        if browse { for (k, v) in client.browseExtra { c[k] = v } }
        if let visitorData { c["visitorData"] = visitorData }
        var ctx: [String: Any] = [
            "client": c,
            "user": ["enableSafetyMode": s.safeSearch, "lockedSafetyMode": false]
        ]
        if let clickTracking { ctx["clickTracking"] = ["clickTrackingParams": clickTracking] }
        if client.screen == "EMBED" { ctx["thirdParty"] = ["embedUrl": "https://www.reddit.com/"] }
        return ctx
    }

    /// POST youtubei/v1/<endpoint>.
    /// - auth: attach the signed-in account's bearer token (TV clients only).
    static func post(_ endpoint: String, _ body: [String: Any], client: InnerTubeClient = .tv,
                     auth: Bool = true, browse: Bool = true, videoId: String? = nil) async throws -> JSON {
        let visitor = await AppInfo.shared.visitorData()
        var payload = body
        payload["context"] = context(client, browse: browse, visitorData: visitor, clickTracking: body["__clickTracking"] as? String)
        payload["__clickTracking"] = nil
        if payload["racyCheckOk"] == nil, ["player", "next"].contains(endpoint) {
            payload["racyCheckOk"] = true
            payload["contentCheckOk"] = true
        }
        var headers: [String: String] = [
            "Content-Type": "application/json",
            "User-Agent": client.userAgent,
            "X-YouTube-Client-Name": String(client.nameId),
            "X-YouTube-Client-Version": client.version,
            "Origin": "https://www.youtube.com"
        ]
        if let r = client.refererURL(videoId: videoId) { headers["Referer"] = r }
        if let visitor { headers["X-Goog-Visitor-Id"] = visitor }
        if auth, client.supportsAuth, let token = try? await AuthService.shared.accessToken() {
            headers["Authorization"] = "Bearer \(token)"
            if let page = await AuthService.shared.pageId() { headers["X-Goog-PageId"] = page }
        }
        let url = URL(string: base + endpoint + "?prettyPrint=false")!
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let (data, resp) = try await HTTP.shared.data(url, method: "POST", headers: headers, body: body)
        if resp.statusCode == 401, auth, client.supportsAuth {
            // token likely expired between check and call: force refresh and retry once
            await AuthService.shared.invalidateAccessToken()
            if let token = try? await AuthService.shared.accessToken() {
                headers["Authorization"] = "Bearer \(token)"
                let (d2, r2) = try await HTTP.shared.data(url, method: "POST", headers: headers, body: body)
                guard (200..<300).contains(r2.statusCode) else { throw APIError.http(r2.statusCode, String(decoding: d2, as: UTF8.self)) }
                return try JSON(data: d2)
            }
        }
        guard (200..<300).contains(resp.statusCode) else { throw APIError.http(resp.statusCode, String(decoding: data, as: UTF8.self)) }
        return try JSON(data: data)
    }
}
