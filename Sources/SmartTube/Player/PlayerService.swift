import Foundation
import VideoToolbox

struct StreamFormat: Identifiable, Hashable {
    var id: String { "\(itag)-\(audioTrackId ?? "")" }
    let itag: Int
    let url: URL
    let mimeType: String
    let codecs: String
    let width: Int?
    let height: Int?
    let fps: Int?
    let bitrate: Int
    let contentLength: Int64?
    let initRange: ClosedRange<Int64>?
    let indexRange: ClosedRange<Int64>?
    let qualityLabel: String?
    let audioTrackId: String?
    let audioTrackName: String?
    let audioIsDefault: Bool
    let audioLanguage: String?
    let isDRC: Bool

    var isVideo: Bool { mimeType.hasPrefix("video/") }
    var isAudio: Bool { mimeType.hasPrefix("audio/") }
    var isMP4: Bool { mimeType.contains("mp4") }
    var isAV1: Bool { codecs.hasPrefix("av01") }
    var isAVC: Bool { codecs.hasPrefix("avc1") }
    var isHDR: Bool { qualityLabel?.contains("HDR") ?? false }
    var label: String {
        if isVideo { return (qualityLabel ?? "\(height ?? 0)p") + " " + (isAV1 ? "AV1" : isAVC ? "AVC" : codecs) }
        return "\(bitrate / 1000) kbps " + (audioTrackName ?? "")
    }
}

struct TranslationLanguage: Hashable {
    let code: String
    let name: String
}

struct CaptionTrack: Identifiable, Hashable {
    var id: String { languageCode + (kind ?? "") + (vssId ?? "") }
    let baseURL: URL
    let name: String
    let languageCode: String
    let kind: String?          // "asr" = auto-generated
    let vssId: String?
    let isTranslatable: Bool
}

struct Storyboard {
    /// Level with best resolution: url template with $M, sheet geometry
    let urlTemplate: String
    let width: Int
    let height: Int
    let count: Int
    let columns: Int
    let rows: Int
    let intervalMs: Int

    func frame(at seconds: Double, duration: Double) -> (url: URL, x: Int, y: Int)? {
        guard count > 0 else { return nil }
        let idx: Int
        if intervalMs > 0 { idx = min(count - 1, Int(seconds * 1000) / intervalMs) }
        else { idx = min(count - 1, Int(seconds / max(duration, 1) * Double(count))) }
        let perSheet = columns * rows
        let sheet = idx / perSheet
        let inSheet = idx % perSheet
        guard let u = URL(string: urlTemplate.replacingOccurrences(of: "$M", with: String(sheet))) else { return nil }
        return (u, (inSheet % columns) * width, (inSheet / columns) * height)
    }
}

struct StreamInfo {
    var videoId: String
    var title: String
    var author: String
    var channelId: String?
    var lengthSeconds: Double
    var isLive: Bool
    var isLiveContent: Bool
    var isUpcoming: Bool
    var isShort: Bool
    var thumbnail: URL?
    var formats: [StreamFormat]
    var hlsURL: URL?
    var captions: [CaptionTrack]
    var translationLanguages: [TranslationLanguage]
    var storyboard: Storyboard?
    var playbackURL: URL?
    var watchtimeURL: URL?
    var cpn: String
    var expires: Date
    var client: String

    var videoFormats: [StreamFormat] { formats.filter(\.isVideo) }
    var audioFormats: [StreamFormat] { formats.filter(\.isAudio) }
}

enum PlayerService {
    static func makeCPN() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }

    static var av1Supported: Bool { VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }

    /// Fetches playable streams, trying clients in SmartTube's order (TV first).
    static func streams(videoId: String, playlistId: String? = nil) async throws -> StreamInfo {
        var lastError: Error = APIError.unplayable("Video unavailable")
        for client in [InnerTubeClient.tvDowngraded, .tv, .webEmbed] {
            do {
                let info = try await streams(videoId: videoId, client: client)
                if !info.formats.isEmpty || info.hlsURL != nil { return info }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static func streams(videoId: String, client: InnerTubeClient) async throws -> StreamInfo {
        let player = try await AppInfo.shared.playerJS(for: client)
        let cpn = makeCPN()
        let body: [String: Any] = [
            "videoId": videoId,
            "cpn": cpn,
            "playbackContext": ["contentPlaybackContext": [
                "signatureTimestamp": player.signatureTimestamp ?? 0,
                "html5Preference": "HTML5_PREF_WANTS",
                "referer": client.refererURL(videoId: videoId) ?? "https://www.youtube.com/"
            ]]
        ]
        let j = try await InnerTube.post("player", body, client: client, browse: false, videoId: videoId)

        let status = j["playabilityStatus"]["status"].string ?? "ERROR"
        let details = j["videoDetails"]
        let isUpcoming = details["isUpcoming"].bool ?? false
        if status != "OK" && !(isUpcoming && status == "LIVE_STREAM_OFFLINE") {
            let reason = j["playabilityStatus"]["reason"].string
                ?? j["playabilityStatus"]["errorScreen"].first("reason").text
                ?? j["playabilityStatus"]["messages"][0].string ?? status
            throw APIError.unplayable(reason)
        }

        let sd = j["streamingData"]
        let rawFormats = sd["adaptiveFormats"].array + sd["formats"].array

        // Collect challenges to solve in one batch
        var nChallenges: [String] = []
        var sigChallenges: [String] = []
        var prepared: [(JSON, URL, String?, String)] = []   // (format, url, sig, sigParam)
        for f in rawFormats {
            var urlStr = f["url"].string
            var sig: String?
            var sp = "sig"
            if urlStr == nil, let cipher = f["signatureCipher"].string ?? f["cipher"].string {
                let q = parseQueryString(cipher)
                urlStr = q["url"]; sig = q["s"]; sp = q["sp"] ?? "signature"
            }
            guard let s = urlStr, let url = URL(string: s) else { continue }
            if let n = url.queryValue("n") { nChallenges.append(n) }
            if let sig { sigChallenges.append(sig) }
            prepared.append((f, url, sig, sp))
        }
        var nMap: [String: String] = [:]
        var sigMap: [String: String] = [:]
        if !nChallenges.isEmpty || !sigChallenges.isEmpty {
            let solved = try await JSSolver.shared.solve(player: player, n: nChallenges, sig: sigChallenges)
            nMap = solved.n; sigMap = solved.sig
        }

        var formats: [StreamFormat] = []
        for (f, rawURL, sig, sp) in prepared {
            var url = rawURL
            if let n = url.queryValue("n") {
                guard let solved = nMap[n] else { continue }
                url = url.settingQuery("n", solved)
            }
            if let sig {
                guard let solved = sigMap[sig] else { continue }
                url = url.settingQuery(sp, solved)
            }
            if url.queryValue("cpn") == nil { url = url.settingQuery("cpn", cpn) }
            let mime = f["mimeType"].string ?? ""
            let codecs = mime.firstMatch(#"codecs="([^"]+)""#) ?? ""
            let at = f["audioTrack"]
            formats.append(StreamFormat(
                itag: f["itag"].int ?? 0, url: url,
                mimeType: mime.components(separatedBy: ";").first ?? mime, codecs: codecs,
                width: f["width"].int, height: f["height"].int, fps: f["fps"].int,
                bitrate: f["bitrate"].int ?? f["averageBitrate"].int ?? 0,
                contentLength: f["contentLength"].string.flatMap { Int64($0) },
                initRange: range(f["initRange"]), indexRange: range(f["indexRange"]),
                qualityLabel: f["qualityLabel"].string,
                audioTrackId: at["id"].string, audioTrackName: at["displayName"].string,
                audioIsDefault: at["audioIsDefault"].bool ?? true,
                audioLanguage: at["id"].string?.components(separatedBy: ".").first,
                isDRC: f["isDrc"].bool ?? false))
        }

        // Captions
        let ct = j["captions"]["playerCaptionsTracklistRenderer"]
        let captions: [CaptionTrack] = ct["captionTracks"].array.compactMap { c in
            guard var s = c["baseUrl"].string else { return nil }
            if s.hasPrefix("/") { s = "https://www.youtube.com" + s }
            guard let u = URL(string: s) else { return nil }
            return CaptionTrack(baseURL: u, name: c["name"].text ?? c["languageCode"].string ?? "?",
                                languageCode: c["languageCode"].string ?? "", kind: c["kind"].string,
                                vssId: c["vssId"].string, isTranslatable: c["isTranslatable"].bool ?? false)
        }
        let translations = ct["translationLanguages"].array.compactMap { t -> TranslationLanguage? in
            guard let code = t["languageCode"].string else { return nil }
            return TranslationLanguage(code: code, name: t["languageName"].text ?? code)
        }

        let expires = TimeInterval(sd["expiresInSeconds"].string.flatMap { Double($0) } ?? 21540)
        let tracking = j["playbackTracking"]
        let isShort = (j["microformat"].first("isShortsEligible").bool ?? false)
            || (details["lengthSeconds"].string.flatMap(Int.init) ?? 1000) <= 180 && j.first("reelPlayerOverlayRenderer").exists

        return StreamInfo(
            videoId: videoId,
            title: details["title"].string ?? "",
            author: details["author"].string ?? "",
            channelId: details["channelId"].string,
            lengthSeconds: details["lengthSeconds"].string.flatMap { Double($0) } ?? 0,
            isLive: details["isLive"].bool ?? false,
            isLiveContent: details["isLiveContent"].bool ?? false,
            isUpcoming: isUpcoming,
            isShort: isShort,
            thumbnail: details["thumbnail"].bestThumbnail,
            formats: formats,
            hlsURL: sd["hlsManifestUrl"].string.flatMap(URL.init(string:)),
            captions: captions,
            translationLanguages: translations,
            storyboard: parseStoryboard(j["storyboards"]),
            playbackURL: tracking["videostatsPlaybackUrl"]["baseUrl"].string.flatMap(URL.init(string:)),
            watchtimeURL: tracking["videostatsWatchtimeUrl"]["baseUrl"].string.flatMap(URL.init(string:)),
            cpn: cpn,
            expires: Date().addingTimeInterval(expires - 60),
            client: client.name)
    }

    private static func range(_ j: JSON) -> ClosedRange<Int64>? {
        guard let s = j["start"].string.flatMap({ Int64($0) }), let e = j["end"].string.flatMap({ Int64($0) }), e >= s else { return nil }
        return s...e
    }

    static func parseStoryboard(_ j: JSON) -> Storyboard? {
        guard let spec = j["playerStoryboardSpecRenderer"]["spec"].string ?? j.first("spec").string else { return nil }
        let parts = spec.components(separatedBy: "|")
        guard parts.count > 1, let base = parts.first else { return nil }
        // choose highest level (last)
        let levelIndex = parts.count - 2
        let level = parts[parts.count - 1].components(separatedBy: "#")
        guard level.count >= 8 else { return nil }
        let w = Int(level[0]) ?? 0, h = Int(level[1]) ?? 0, count = Int(level[2]) ?? 0
        let cols = Int(level[3]) ?? 1, rows = Int(level[4]) ?? 1, interval = Int(level[5]) ?? 0
        let name = level[6], sigh = level[7]
        let url = base.replacingOccurrences(of: "$L", with: String(levelIndex))
            .replacingOccurrences(of: "$N", with: name) + "&sigh=" + sigh
        return Storyboard(urlTemplate: url, width: w, height: h, count: count, columns: cols, rows: rows, intervalMs: interval)
    }

    // MARK: Watch history tracking (videostats), as SmartTube's TrackingService

    static func reportPlayback(_ info: StreamInfo) async {
        guard Settings.shared.historyEnabled, let base = info.playbackURL, await AuthService.shared.isSignedIn else { return }
        let url = base.settingQuery("ver", "2").settingQuery("cpn", info.cpn).settingQuery("cmt", "0")
            .settingQuery("len", String(format: "%.3f", info.lengthSeconds)).settingQuery("of", nil)
        await ping(url)
    }

    static func reportWatchtime(_ info: StreamInfo, from start: Double, to end: Double) async {
        guard Settings.shared.historyEnabled, let base = info.watchtimeURL, await AuthService.shared.isSignedIn else { return }
        let url = base.settingQuery("ver", "2").settingQuery("cpn", info.cpn)
            .settingQuery("st", String(format: "%.3f", start)).settingQuery("et", String(format: "%.3f", end))
            .settingQuery("cmt", String(format: "%.3f", end))
            .settingQuery("len", String(format: "%.3f", info.lengthSeconds))
        await ping(url)
    }

    private static func ping(_ url: URL) async {
        var headers = ["User-Agent": InnerTubeClient.tvDowngraded.userAgent]
        if let token = try? await AuthService.shared.accessToken() { headers["Authorization"] = "Bearer \(token)" }
        _ = try? await HTTP.shared.data(url, headers: headers)
    }
}
