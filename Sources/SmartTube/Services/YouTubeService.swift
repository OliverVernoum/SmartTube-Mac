import Foundation

struct SearchFilters: Equatable {
    enum Sort: Int, CaseIterable { case relevance = 0, rating = 1, date = 2, views = 3 }
    enum UploadDate: Int, CaseIterable { case any = 0, hour = 1, today = 2, week = 3, month = 4, year = 5 }
    enum Kind: Int, CaseIterable { case any = 0, video = 1, channel = 2, playlist = 3, movie = 4 }
    enum Duration: Int, CaseIterable { case any = 0, short = 1, long = 2, medium = 3 }
    var sort: Sort = .relevance
    var uploadDate: UploadDate = .any
    var kind: Kind = .any
    var duration: Duration = .any
    var live = false
    var hd = false
    var fourK = false
    var subtitles = false

    var isDefault: Bool { self == SearchFilters() }

    /// Encodes to the protobuf "params" string used by the search endpoint.
    var params: String? {
        if isDefault { return nil }
        var filters = Data()
        func varint(_ field: Int, _ v: Int) { filters.append(UInt8(field << 3)); filters.append(UInt8(v)) }
        if uploadDate != .any { varint(1, uploadDate.rawValue) }
        if kind != .any { varint(2, kind.rawValue) }
        if duration != .any { varint(3, duration.rawValue) }
        if hd { varint(4, 1) }
        if subtitles { varint(5, 1) }
        if live { varint(8, 1) }
        if fourK { varint(14, 1) }
        var msg = Data()
        if sort != .relevance { msg.append(0x08); msg.append(UInt8(sort.rawValue)) }
        if !filters.isEmpty { msg.append(0x12); msg.append(UInt8(filters.count)); msg.append(filters) }
        return msg.base64EncodedString()
    }
}

/// All content endpoints (port of SmartTube's ContentService / MediaItemService pieces).
enum YouTubeService {

    // MARK: Browse

    static func browse(_ browseId: String, params: String? = nil, query: String? = nil, client: InnerTubeClient = .tv) async throws -> BrowsePage {
        var body: [String: Any] = ["browseId": browseId]
        if let params { body["params"] = params }
        if let query { body["query"] = query }
        let j = try await InnerTube.post("browse", body, client: client)
        return Parser.page(j)
    }

    static func continuation(_ token: String, endpoint: String = "browse", client: InnerTubeClient = .tv) async throws -> BrowsePage {
        let j = try await InnerTube.post(endpoint, ["continuation": token], client: client)
        return Parser.page(j)
    }

    static func section(_ section: AppSection) async throws -> BrowsePage {
        let signedIn = await AuthService.shared.isSignedIn
        if section.requiresAuth && !signedIn { throw APIError.notSignedIn }
        switch section {
        case .home:
            var page = try await browse("default")
            if page.allItems.isEmpty {
                // Anonymous TV home is empty: compose from topic feeds (as SmartTube shows rows)
                async let g = try? browse("FEtopics_gaming")
                async let n = try? browse("FEtopics_news")
                async let s = try? browse("FEtopics_sports")
                async let l = try? browse("FEtopics_live")
                async let m = try? browse("FEtopics_music")
                for p in await [m, g, l, n, s] { if let p { page.shelves += p.shelves.filter { !$0.items.isEmpty } } }
            }
            page.shelves = page.shelves.map { filterShelf($0, hideShorts: Settings.shared.hideShortsHome) }
            return page
        case .shorts:
            return try await shorts()
        case .subscriptions:
            var page = try await browse("FEsubscriptions")
            page.shelves = page.shelves.map { filterShelf($0, hideShorts: Settings.shared.hideShortsSubscriptions) }
            return page
        case .history:
            var page = try await browse("FEhistory")
            page.shelves = page.shelves.map { filterShelf($0, hideShorts: Settings.shared.hideShortsHistory, applyWatched: false) }
            return page
        case .channels:
            return try await subscribedChannels()
        case .playlists:
            var page = try await browse("FEplaylist_aggregation")
            if !page.allItems.contains(where: { $0.playlistId == "WL" }) {
                var wl = MediaItem(); wl.kind = .playlist; wl.playlistId = "WL"; wl.title = "Watch later"
                var ll = MediaItem(); ll.kind = .playlist; ll.playlistId = "LL"; ll.title = "Liked videos"
                page.shelves.insert(Shelf(title: "", items: [wl, ll]), at: 0)
            }
            return page
        case .notifications:
            return try await notifications()
        case .trending:
            return try await browse("FEtrending", params: "6gQJRkVleHBsb3Jl")
        case .channelGroups, .settings:
            return BrowsePage()
        default:
            guard let id = section.browseId else { return BrowsePage() }
            var page = try await browse(id)
            page.shelves = page.shelves.map { filterShelf($0, hideShorts: false) }
            return page
        }
    }

    static func filterShelf(_ s: Shelf, hideShorts: Bool, applyWatched: Bool = true) -> Shelf {
        let st = Settings.shared
        let blocked = st.blockedChannels
        var shelf = s
        shelf.items = s.items.filter { m in
            if hideShorts && m.kind == .short { return false }
            if st.hideUpcoming && m.kind == .upcoming { return false }
            if applyWatched && st.hideWatched, let p = m.watchedPercent, p >= Double(st.hideWatchedPercent) { return false }
            if let c = m.channelId, blocked[c] != nil { return false }
            return true
        }
        return shelf
    }

    /// Subscribed channels list (TV subscriptions page exposes channels as tabs / tiles).
    static func subscribedChannels() async throws -> BrowsePage {
        let j = try await InnerTube.post("browse", ["browseId": "FEsubscriptions"])
        var channels: [MediaItem] = []
        // TV: tvSecondaryNavRenderer sections -> tvSecondaryNavSectionRenderer.tabs[].tabRenderer (one per channel)
        for tab in j.findAll("tabRenderer") {
            let be = tab["endpoint"]["browseEndpoint"]
            guard let id = be["browseId"].string, id.hasPrefix("UC") else { continue }
            var m = MediaItem()
            m.kind = .channel
            m.channelId = id
            m.params = be["params"].string
            m.title = tab["title"].text ?? ""
            m.thumbnail = tab["thumbnail"].bestThumbnail
            m.channelThumbnail = m.thumbnail
            if tab["presentationStyle"]["style"].string == "TAB_PRESENTATION_STYLE_NEW_CONTENT" { m.badges.append("NEW") }
            channels.append(m)
        }
        if channels.isEmpty {
            // fallback: web channel list
            let p = try await browse("FEchannels", client: .web)
            return p
        }
        var page = BrowsePage()
        page.shelves = [Shelf(title: "", items: channels)]
        return page
    }

    static func shorts() async throws -> BrowsePage {
        let first = try await InnerTube.post("reel/reel_item_watch",
                                             ["disablePlayerResponse": true, "inputType": "REEL_WATCH_INPUT_TYPE_SEEDLESS", "params": "CA8%3D"],
                                             client: .web, auth: false)
        var items: [MediaItem] = []
        if let vid = first["replacementEndpoint"]["reelWatchEndpoint"]["videoId"].string {
            items.append(shortItem(vid))
        }
        var cont = first["sequenceContinuation"].string
        if let seq = cont {
            let next = try await InnerTube.post("reel/reel_watch_sequence", ["sequenceParams": seq], client: .web, auth: false)
            items += next["entries"].array.compactMap { $0.first("reelWatchEndpoint")["videoId"].string }.map(shortItem)
            cont = next["continuationEndpoint"].first("token").string
        }
        var page = BrowsePage()
        page.shelves = [Shelf(title: "", items: items, continuation: cont)]
        page.continuation = cont.map { "reel:" + $0 }
        return page
    }

    static func moreShorts(_ token: String) async throws -> BrowsePage {
        let next = try await InnerTube.post("reel/reel_watch_sequence", ["sequenceParams": token], client: .web, auth: false)
        let items = next["entries"].array.compactMap { $0.first("reelWatchEndpoint")["videoId"].string }.map(shortItem)
        var page = BrowsePage()
        page.shelves = [Shelf(title: "", items: items)]
        page.continuation = next["continuationEndpoint"].first("token").string.map { "reel:" + $0 }
        return page
    }

    static func shortItem(_ id: String) -> MediaItem {
        var m = MediaItem.video(id)
        m.kind = .short
        m.thumbnail = URL(string: "https://i.ytimg.com/vi/\(id)/oar2.jpg")
        return m
    }

    /// Generic "load more" that understands our pseudo tokens.
    static func more(_ token: String, endpoint: String = "browse") async throws -> BrowsePage {
        if token.hasPrefix("reel:") { return try await moreShorts(String(token.dropFirst(5))) }
        if token.hasPrefix("web:") { return try await continuation(String(token.dropFirst(4)), endpoint: endpoint, client: .web) }
        return try await continuation(token, endpoint: endpoint)
    }

    static func notifications() async throws -> BrowsePage {
        let j = try await InnerTube.post("notification/get_notification_menu", ["notificationsMenuRequestType": "NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX"], client: .tv)
        var items: [MediaItem] = []
        for n in j.findAll("notificationRenderer") {
            var m = MediaItem()
            m.videoId = n["navigationEndpoint"]["watchEndpoint"]["videoId"].string
            m.title = n["shortMessage"].text ?? ""
            m.info = n["sentTimeText"].text
            m.thumbnail = n["videoThumbnail"].bestThumbnail
            m.channelThumbnail = n["thumbnail"].bestThumbnail
            if !(n["read"].bool ?? true) { m.badges.append("NEW") }
            items.append(m)
        }
        if items.isEmpty { items = Parser.items(in: j) }
        var page = BrowsePage()
        page.shelves = [Shelf(title: "", items: items)]
        page.continuation = Parser.continuationToken(j)
        return page
    }

    // MARK: Channel

    enum ChannelSection: String, CaseIterable {
        case home, videos, shorts, live, playlists, releases, community, search
        var params: String {
            switch self {
            case .home: return "EghmZWF0dXJlZPIGBAoCMgA%3D"
            case .videos: return "EgZ2aWRlb3PyBgQKAjoA"
            case .shorts: return "EgZzaG9ydHPyBgUKA5oBAA%3D%3D"
            case .live: return "EgdzdHJlYW1z8gYECgJ6AA%3D%3D"
            case .playlists: return "EglwbGF5bGlzdHPyBgQKAkIA"
            case .releases: return "EghyZWxlYXNlc_IGBQoDsgEA"
            case .community: return "Egljb21tdW5pdHnyBgQKAkoA"
            case .search: return "EgZzZWFyY2jyBgQKAloA"
            }
        }
        var title: String { rawValue.capitalized }
    }

    static func channel(_ id: String, section: ChannelSection? = nil, params: String? = nil, query: String? = nil) async throws -> BrowsePage {
        var page = try await browse(id, params: params ?? section?.params, query: query)
        if Settings.shared.hideShortsChannel { page.shelves = page.shelves.map { filterShelf($0, hideShorts: true) } }
        return page
    }

    static func playlist(_ id: String) async throws -> BrowsePage {
        let bid = id.hasPrefix("VL") ? id : "VL" + id
        var page = try await browse(bid)
        if page.allItems.isEmpty { page = try await browse(bid, client: .web) }
        return page
    }

    // MARK: Search

    static func search(_ query: String, filters: SearchFilters = SearchFilters()) async throws -> BrowsePage {
        var body: [String: Any] = ["query": query]
        if let p = filters.params { body["params"] = p }
        let j = try await InnerTube.post("search", body)
        var page = Parser.page(j)
        if Settings.shared.hideShortsSearch { page.shelves = page.shelves.map { filterShelf($0, hideShorts: true) } }
        if Settings.shared.searchHistoryEnabled {
            var h = Settings.shared.searchHistory.filter { $0 != query }
            h.insert(query, at: 0)
            Settings.shared.searchHistory = Array(h.prefix(50))
        }
        return page
    }

    static func suggestions(_ query: String) async -> [String] {
        guard !query.isEmpty else { return Settings.shared.searchHistory }
        let s = Settings.shared
        var c = URLComponents(string: "https://suggestqueries-clients6.youtube.com/complete/search")!
        c.queryItems = [.init(name: "client", value: "youtube"), .init(name: "ds", value: "yt"),
                        .init(name: "q", value: query), .init(name: "hl", value: s.language), .init(name: "gl", value: s.country.lowercased()),
                        .init(name: "xhr", value: "t")]
        guard let url = c.url, let resp = try? await HTTP.shared.data(url, headers: ["User-Agent": InnerTubeClient.uaWeb]),
              let j = try? JSON(data: resp.0) else { return [] }
        let history = s.searchHistory.filter { $0.lowercased().hasPrefix(query.lowercased()) }
        let remote = j[1].array.compactMap { $0[0].string }
        var seen = Set<String>()
        return (history + remote).filter { seen.insert($0).inserted }
    }

    // MARK: Watch page (next)

    static func details(videoId: String, playlistId: String? = nil, playlistIndex: Int? = nil, params: String? = nil) async throws -> VideoDetails {
        var body: [String: Any] = ["videoId": videoId]
        if let playlistId { body["playlistId"] = playlistId }
        if let playlistIndex { body["playlistIndex"] = playlistIndex }
        if let params { body["params"] = params }
        let j = try await InnerTube.post("next", body, videoId: videoId)
        return parseDetails(j, videoId: videoId)
    }

    static func parseDetails(_ j: JSON, videoId: String) -> VideoDetails {
        var d = VideoDetails(videoId: videoId)
        let meta = j["contents"].first("videoMetadataRenderer")
        d.title = meta["title"].text ?? j["contents"].first("videoPrimaryInfoRenderer")["title"].text ?? ""
        d.date = meta["dateText"].text ?? meta["publishedTimeText"].text
        d.viewCount = meta["viewCountText"].text ?? meta["viewCount"].first("viewCountText").text
        d.description = meta["description"].text ?? ""
        let owner = meta["owner"]["videoOwnerRenderer"].exists ? meta["owner"]["videoOwnerRenderer"] : j["contents"].first("videoOwnerRenderer")
        d.channelName = owner["title"].text
        d.channelId = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        d.channelAvatar = owner["thumbnail"].bestThumbnail
        d.subscriberCount = owner["subscriberCountText"].text
        let sub = owner.first("subscribeButtonRenderer")
        d.subscribed = sub["subscribed"].bool ?? false
        d.subscribeParams = sub.first("subscribeEndpoint")["params"].string
        d.notificationState = sub.first("subscriptionNotificationToggleButtonRenderer")["currentStateId"].string

        // Description panel (richer, includes full text)
        for panel in j["engagementPanels"].array {
            let e = panel["engagementPanelSectionListRenderer"]
            let id = e["panelIdentifier"].string ?? ""
            if id == "comment-item-section" {
                d.commentsToken = e["content"].first("reloadContinuationData")["continuation"].string ?? e["content"].first("continuationCommand")["token"].string
                d.commentsCount = e["header"]["engagementPanelTitleHeaderRenderer"]["contextualInfo"].text
            }
            if d.description.isEmpty {
                let desc = e["content"].first("richTextListViewModel")["segments"].array.compactMap { $0.first("content").string }.joined(separator: "\n")
                if !desc.isEmpty { d.description = desc }
            }
            if d.description.isEmpty, let attr = e["content"].first("expandableVideoDescriptionBodyRenderer")["attributedDescriptionBodyText"]["content"].string {
                d.description = attr
            }
            for marker in e.findAll("macroMarkersListItemRenderer") {
                guard let t = marker["title"].text, let start = marker.first("watchEndpoint")["startTimeSeconds"].double else { continue }
                if !d.chapters.contains(where: { $0.start == start }) {
                    d.chapters.append(Chapter(title: t, start: start, thumbnail: marker["thumbnail"].bestThumbnail))
                }
            }
        }
        // Chapters on TV come from the player bar markers
        for ch in j.findAll("chapterRenderer") {
            guard let t = ch["title"].text, let ms = ch["timeRangeStartMillis"].double else { continue }
            if !d.chapters.contains(where: { $0.start == ms / 1000 }) {
                d.chapters.append(Chapter(title: t, start: ms / 1000, thumbnail: ch["thumbnail"].bestThumbnail))
            }
        }
        d.chapters.sort { $0.start < $1.start }

        // Like state (TV transport controls or web segmented button)
        let like = j.first("likeButtonRenderer")
        if like.exists {
            d.likeStatus = LikeStatus(rawValue: like["likeStatus"].string ?? "") ?? .none
            d.likeCount = like["likeCountText"].text ?? like["likeCount"].string
        } else if let l = j.first("likeButtonViewModel").first("toggleButtonViewModel").first("defaultButtonViewModel")["buttonViewModel"]["title"].string {
            d.likeCount = l
        }

        // Related + autoplay
        let pivot = j["contents"]["singleColumnWatchNextResults"]["pivot"]
        if pivot.exists {
            let p = Parser.page(JSON.object(["contents": pivot]))
            d.related = p.shelves
            d.relatedContinuation = Parser.continuationToken(pivot)
        } else {
            let sec = j["contents"].first("secondaryResults")
            d.related = [Shelf(title: "Related", items: Parser.items(in: sec))]
            d.relatedContinuation = sec.findAll("continuationItemRenderer").last?.first("token").string.map { "web:" + $0 }
        }
        if let next = j["contents"].first("autoplay").first("watchEndpoint")["videoId"].string {
            var m = MediaItem.video(next)
            m.playlistId = j["contents"].first("autoplay").first("watchEndpoint")["playlistId"].string
            m.title = d.related.flatMap(\.items).first { $0.videoId == next }?.title ?? ""
            d.autoplayNext = m
        }
        // Playlist queue
        let pl = j["contents"].first("playlist")["playlist"]
        if pl.exists, let pid = pl["playlistId"].string {
            let items = Parser.items(in: pl["contents"])
            d.playlist = PlaylistQueue(playlistId: pid, title: pl["title"].text ?? "",
                                       items: items, currentIndex: pl["currentIndex"].int ?? 0)
        }
        // Live chat
        d.liveChatContinuation = j["contents"].first("liveChatRenderer").first("reloadContinuationData")["continuation"].string
            ?? j.first("liveChatRenderer").first("reloadContinuationData")["continuation"].string
        d.isLive = d.liveChatContinuation != nil || meta["badges"].findAll("label").contains { $0.string == "LIVE" }
        return d
    }

    // MARK: Comments

    static func comments(_ token: String) async throws -> CommentsPage {
        let j = try await InnerTube.post("next", ["continuation": token])
        var page = CommentsPage(comments: [], continuation: nil)
        for th in j.findAll("commentThreadRenderer") {
            guard var c = parseComment(th["comment"]["commentRenderer"]) else { continue }
            c.repliesToken = th["replies"].first("reloadContinuationData")["continuation"].string
                ?? th["replies"].first("continuationCommand")["token"].string
                ?? c.repliesToken
            page.comments.append(c)
        }
        if page.comments.isEmpty {
            // replies page
            for cr in j.findAll("commentRenderer") { if let c = parseComment(cr) { page.comments.append(c) } }
        }
        // view-model based comments (web)
        if page.comments.isEmpty {
            for e in j.findAll("commentEntityPayload") {
                let p = e["properties"]
                page.comments.append(Comment(id: p["commentId"].string ?? UUID().uuidString,
                                             author: e["author"]["displayName"].string ?? "",
                                             authorThumbnail: URL(string: e["author"]["avatarThumbnailUrl"].string ?? ""),
                                             authorChannelId: e["author"]["channelId"].string,
                                             text: p["content"]["content"].string ?? "",
                                             published: p["publishedTime"].string,
                                             likes: e["toolbar"]["likeCountNotliked"].string,
                                             repliesCount: e["toolbar"]["replyCount"].string))
            }
        }
        page.continuation = j.findAll("nextContinuationData").last?["continuation"].string
            ?? j.findAll("continuationItemRenderer").last?.first("token").string
        for item in j.first("sortFilterSubMenuRenderer")["subMenuItems"].array {
            if let t = item["title"].string, let tok = item.first("continuation").first("continuation").string ?? item.first("token").string {
                page.sortOptions.append(SortOption(title: t, token: tok))
            }
        }
        page.title = j.first("engagementPanelTitleHeaderRenderer")["title"].text
        return page
    }

    static func parseComment(_ c: JSON) -> Comment? {
        guard c.exists else { return nil }
        var cm = Comment(id: c["commentId"].string ?? UUID().uuidString,
                         author: c["authorText"].text ?? "",
                         authorThumbnail: c["authorThumbnail"].bestThumbnail,
                         authorChannelId: c["authorEndpoint"]["browseEndpoint"]["browseId"].string,
                         text: c["contentText"].text ?? "",
                         published: c["publishedTimeText"].text,
                         likes: c["voteCount"].text,
                         isLiked: c["isLiked"].bool ?? false,
                         repliesCount: c["replyCount"].string)
        cm.isPinned = c["pinnedCommentBadge"].exists
        cm.isHearted = c.first("creatorHeart").exists
        cm.repliesToken = c["detailViewEndpoint"].first("reloadContinuationData")["continuation"].string
        for a in c.findAll("performCommentActionEndpoint") {
            guard let action = a["action"].string else { continue }
            if cm.likeAction == nil { cm.likeAction = action } else if cm.unlikeAction == nil { cm.unlikeAction = action }
        }
        return cm
    }

    // MARK: Live chat

    static func liveChat(_ continuation: String) async throws -> (messages: [ChatMessage], next: String?, pollMs: Int) {
        let j = try await InnerTube.post("live_chat/get_live_chat", ["continuation": continuation], client: .web, auth: false)
        var msgs: [ChatMessage] = []
        for a in j.findAll("addChatItemAction") {
            let item = a["item"]
            let r = item["liveChatTextMessageRenderer"].exists ? item["liveChatTextMessageRenderer"] : item["liveChatPaidMessageRenderer"]
            guard r.exists else { continue }
            var m = ChatMessage(id: r["id"].string ?? UUID().uuidString,
                                author: r["authorName"].text ?? "",
                                authorPhoto: r["authorPhoto"].bestThumbnail,
                                message: r["message"]["runs"].array.map { run in
                                    run["text"].string ?? run["emoji"]["shortcuts"][0].string ?? ""
                                }.joined())
            m.superChat = r["purchaseAmountText"].text
            for b in r["authorBadges"].array {
                let icon = b["liveChatAuthorBadgeRenderer"]["icon"]["iconType"].string ?? ""
                if icon == "OWNER" { m.isOwner = true }
                if icon == "MODERATOR" { m.isModerator = true }
                if b["liveChatAuthorBadgeRenderer"]["customThumbnail"].exists { m.isMember = true }
            }
            msgs.append(m)
        }
        let cont = j.first("invalidationContinuationData").exists ? j.first("invalidationContinuationData")
            : j.first("timedContinuationData").exists ? j.first("timedContinuationData") : j.first("reloadContinuationData")
        return (msgs, cont["continuation"].string, cont["timeoutMs"].int ?? 3000)
    }
}
