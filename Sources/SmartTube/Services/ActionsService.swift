import Foundation

/// Account actions: like/dislike, subscribe, playlists, feedback, history management.
enum ActionsService {
    @discardableResult
    private static func call(_ endpoint: String, _ body: [String: Any]) async throws -> JSON {
        guard await AuthService.shared.isSignedIn else { throw APIError.notSignedIn }
        return try await InnerTube.post(endpoint, body, client: .tv, browse: false)
    }

    // MARK: Likes

    static func setLike(_ videoId: String, from old: LikeStatus, to new: LikeStatus) async throws {
        let target = ["target": ["videoId": videoId]]
        switch (old, new) {
        case (_, .like): try await call("like/like", target)
        case (_, .dislike): try await call("like/dislike", target)
        case (.like, .none): try await call("like/removelike", target)
        case (.dislike, .none): try await call("like/removedislike", target)
        default: break
        }
    }

    // MARK: Subscriptions

    static func subscribe(_ channelId: String, params: String? = nil) async throws {
        try await call("subscription/subscribe", ["channelIds": [channelId], "params": params ?? ""])
    }

    static func unsubscribe(_ channelId: String, params: String? = nil) async throws {
        try await call("subscription/unsubscribe", ["channelIds": [channelId], "params": params ?? ""])
    }

    enum Bell: Int, CaseIterable { case none = 1, all = 2, personalized = 3
        var title: String { switch self { case .none: return "None"; case .all: return "All"; case .personalized: return "Personalized" } }
    }

    /// Notification bell via notification/modify_channel_preference.
    /// Params layout observed in TV responses: {1: channelId, 2: {1: state}, 3: 0, 4: 4}
    static func setNotifications(_ channelId: String, bell: Bell) async throws {
        var msg = Data([0x0A, UInt8(channelId.utf8.count)])
        msg.append(contentsOf: Array(channelId.utf8))
        msg.append(contentsOf: [0x12, 0x02, 0x08, UInt8(bell.rawValue), 0x18, 0x00, 0x20, 0x04])
        try await call("notification/modify_channel_preference", ["params": msg.base64EncodedString()])
    }

    // MARK: Playlists

    static func playlistsContaining(_ videoId: String) async throws -> [PlaylistInfo] {
        let j = try await call("playlist/get_add_to_playlist", ["videoIds": [videoId]])
        return j.findAll("playlistAddToOptionRenderer").compactMap { p in
            guard let id = p["playlistId"].string else { return nil }
            return PlaylistInfo(id: id, title: p["title"].text ?? id, containsVideo: p["containsSelectedVideos"].string == "ALL")
        }
    }

    static func addToPlaylist(_ playlistId: String, videoId: String) async throws {
        try await call("browse/edit_playlist", ["playlistId": playlistId,
                                                "actions": [["addedVideoId": videoId, "action": "ACTION_ADD_VIDEO"]]])
    }

    static func removeFromPlaylist(_ playlistId: String, videoId: String) async throws {
        try await call("browse/edit_playlist", ["playlistId": playlistId,
                                                "actions": [["removedVideoId": videoId, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"]]])
    }

    static func renamePlaylist(_ playlistId: String, name: String) async throws {
        try await call("browse/edit_playlist", ["playlistId": playlistId,
                                                "actions": [["playlistName": name, "action": "ACTION_SET_PLAYLIST_NAME"]]])
    }

    static func createPlaylist(_ title: String, videoId: String? = nil) async throws {
        var body: [String: Any] = ["title": title]
        if let videoId { body["videoIds"] = [videoId] }
        try await call("playlist/create", body)
    }

    static func deletePlaylist(_ playlistId: String) async throws {
        try await call("playlist/delete", ["playlistId": playlistId])
    }

    static func savePlaylist(_ playlistId: String) async throws {
        try await call("like/like", ["target": ["playlistId": playlistId]])
    }

    static func unsavePlaylist(_ playlistId: String) async throws {
        try await call("like/removelike", ["target": ["playlistId": playlistId]])
    }

    // MARK: Feedback

    static func feedback(_ token: String) async throws {
        try await call("feedback", ["feedbackTokens": [token]])
    }

    // MARK: History

    static func pauseWatchHistory() async throws { try await call("history/pause_watch_history", [:]) }
    static func resumeWatchHistory() async throws { try await call("history/resume_watch_history", [:]) }
    static func clearWatchHistory() async throws { try await call("history/clear_watch_history", [:]) }
    static func clearSearchHistory() async throws {
        Settings.shared.searchHistory = []
        if await AuthService.shared.isSignedIn { try await call("history/clear_search_history", [:]) }
    }

    // MARK: Comments

    static func commentAction(_ action: String) async throws {
        try await call("comment/perform_comment_action", ["actions": [action]])
    }
}

// MARK: - SponsorBlock

struct SponsorSegment: Identifiable, Hashable {
    var id: String { uuid }
    let uuid: String
    let category: SponsorCategory
    let start: Double
    let end: Double
    let actionType: String
}

enum SponsorBlockService {
    static func segments(_ videoId: String) async -> [SponsorSegment] {
        let st = Settings.shared
        guard st.sponsorBlockEnabled else { return [] }
        let cats = SponsorCategory.allCases.filter { st.sponsorAction($0) != .nothing || st.sponsorShowOnSeekbar }
        let catJSON = "[" + cats.map { "\"\($0.rawValue)\"" }.joined(separator: ",") + "]"
        var c = URLComponents(string: "https://sponsor.ajay.app/api/skipSegments")!
        c.queryItems = [.init(name: "videoID", value: videoId), .init(name: "categories", value: catJSON),
                        .init(name: "actionTypes", value: "[\"skip\",\"mute\",\"poi\",\"full\"]")]
        guard let url = c.url, let j = try? await HTTP.shared.json(url) else { return [] }
        return j.array.compactMap { s in
            guard let cat = SponsorCategory(rawValue: s["category"].string ?? ""),
                  let seg = s["segment"].array.first?.double, let end = s["segment"].array.last?.double else { return nil }
            if end - seg < st.sponsorMinDuration && cat != .poi_highlight { return nil }
            return SponsorSegment(uuid: s["UUID"].string ?? UUID().uuidString, category: cat, start: seg, end: end,
                                  actionType: s["actionType"].string ?? "skip")
        }
    }
}

// MARK: - Return YouTube Dislike

enum DislikeService {
    static func votes(_ videoId: String) async -> (likes: Int, dislikes: Int)? {
        guard Settings.shared.returnDislikes,
              let url = URL(string: "https://returnyoutubedislikeapi.com/votes?videoId=\(videoId)"),
              let j = try? await HTTP.shared.json(url),
              let d = j["dislikes"].int else { return nil }
        return (j["likes"].int ?? 0, d)
    }
}

// MARK: - DeArrow

actor DeArrowService {
    static let shared = DeArrowService()
    private var cache: [String: (title: String?, thumb: URL?)] = [:]

    func branding(_ videoId: String) async -> (title: String?, thumb: URL?) {
        let st = Settings.shared
        guard st.deArrowTitles || st.deArrowThumbnails else { return (nil, nil) }
        if let c = cache[videoId] { return c }
        var result: (String?, URL?) = (nil, nil)
        if let url = URL(string: "https://sponsor.ajay.app/api/branding?videoID=\(videoId)"),
           let j = try? await HTTP.shared.json(url) {
            if st.deArrowTitles, let t = j["titles"].array.first(where: { ($0["votes"].int ?? 0) >= 0 || ($0["locked"].bool ?? false) })?["title"].string {
                result.0 = t.replacingOccurrences(of: ">", with: "")
            }
            if st.deArrowThumbnails, let thumb = j["thumbnails"].array.first(where: { !($0["original"].bool ?? true) }),
               let ts = thumb["timestamp"].double {
                result.1 = URL(string: "https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=\(videoId)&time=\(ts)")
            }
        }
        cache[videoId] = result
        return result
    }
}
