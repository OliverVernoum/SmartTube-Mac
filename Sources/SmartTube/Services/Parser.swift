import Foundation

/// Converts InnerTube renderers (TV, web, view-models) into app models.
/// Deliberately tolerant: YouTube changes shapes often, so we search recursively.
enum Parser {
    static let itemKeys = [
        "tileRenderer", "lockupViewModel", "videoRenderer", "gridVideoRenderer", "compactVideoRenderer",
        "reelItemRenderer", "shortsLockupViewModel", "gridChannelRenderer", "channelRenderer",
        "gridPlaylistRenderer", "playlistRenderer", "compactPlaylistRenderer", "playlistVideoRenderer",
        "playlistPanelVideoRenderer", "pivotVideoRenderer", "compactRadioRenderer", "radioRenderer",
        "gridRadioRenderer", "richItemRenderer"
    ]

    // MARK: Items

    static func item(from wrapper: JSON) -> MediaItem? {
        for key in itemKeys {
            let r = wrapper[key]
            guard r.exists else { continue }
            switch key {
            case "tileRenderer": return tile(r)
            case "lockupViewModel": return lockup(r)
            case "shortsLockupViewModel": return shortsLockup(r)
            case "reelItemRenderer": return reel(r)
            case "gridChannelRenderer", "channelRenderer": return channel(r)
            case "gridPlaylistRenderer", "playlistRenderer", "compactPlaylistRenderer",
                 "compactRadioRenderer", "radioRenderer", "gridRadioRenderer": return playlist(r)
            case "richItemRenderer": return item(from: r["content"])
            default: return webVideo(r)
            }
        }
        return nil
    }

    /// Recursively collects every item under `root` (stops descending into an item once matched).
    static func items(in root: JSON) -> [MediaItem] {
        var out: [MediaItem] = []
        var seen = Set<String>()
        func walk(_ j: JSON) {
            switch j {
            case .object(let d):
                for key in itemKeys where d[key] != nil {
                    if let m = item(from: j), seen.insert(m.id).inserted { out.append(m) }
                    return
                }
                for (k, v) in d where k != "engagementPanels" && k != "frameworkUpdates" { walk(v) }
            case .array(let a):
                for v in a { walk(v) }
            default: break
            }
        }
        walk(root)
        return out.filter { !($0.title.isEmpty && $0.videoId == nil && $0.playlistId == nil && $0.channelId == nil) }
    }

    static func tile(_ t: JSON) -> MediaItem {
        var m = MediaItem()
        let cmd = t["onSelectCommand"]
        m.clickTracking = cmd["clickTrackingParams"].string
        let contentType = t["contentType"].string ?? ""
        m.title = t["metadata"]["tileMetadataRenderer"]["title"].text ?? ""
        m.thumbnail = t["header"]["tileHeaderRenderer"]["thumbnail"].bestThumbnail

        var lines: [[String]] = []
        for line in t["metadata"]["tileMetadataRenderer"]["lines"].array {
            var parts: [String] = []
            for li in line["lineRenderer"]["items"].array {
                let lir = li["lineItemRenderer"]
                if let label = lir["badge"]["metadataBadgeRenderer"]["label"].string {
                    m.badges.append(label)
                } else if let txt = lir["text"].text, txt != "•" {
                    parts.append(txt)
                }
            }
            if !parts.isEmpty { lines.append(parts) }
        }
        if let first = lines.first { m.subtitle = first.joined(separator: " ") }
        if lines.count > 1 { m.info = lines.dropFirst().map { $0.joined(separator: " • ") }.joined(separator: " • ") }

        for ov in t["header"]["tileHeaderRenderer"]["thumbnailOverlays"].array {
            if let ts = ov["thumbnailOverlayTimeStatusRenderer"].exists ? ov["thumbnailOverlayTimeStatusRenderer"] : nil {
                let style = ts["style"].string ?? ""
                if style == "LIVE" { m.kind = .live } else if style == "UPCOMING" { m.kind = .upcoming }
                if let txt = ts["text"].text, style != "LIVE" { m.duration = txt; m.durationSeconds = parseDuration(txt) }
            }
            if let p = ov["thumbnailOverlayResumePlaybackRenderer"]["percentDurationWatched"].double { m.watchedPercent = p }
        }
        if m.badges.contains(where: { $0.uppercased() == "LIVE" }) { m.kind = .live }

        if let we = cmd["watchEndpoint"].exists ? cmd["watchEndpoint"] : nil {
            m.videoId = we["videoId"].string
            m.playlistId = we["playlistId"].string
            m.playlistIndex = we["index"].int
            m.params = we["params"].string
            if let st = we["startTimeSeconds"].double { m.startSeconds = st }
        }
        if cmd["reelWatchEndpoint"].exists {
            m.videoId = cmd["reelWatchEndpoint"]["videoId"].string
            m.kind = .short
        }
        if cmd["watchPlaylistEndpoint"].exists {
            m.playlistId = cmd["watchPlaylistEndpoint"]["playlistId"].string
            m.kind = .playlist
        }
        if cmd["browseEndpoint"].exists {
            let be = cmd["browseEndpoint"]
            let bid = be["browseId"].string ?? ""
            if bid.hasPrefix("VL") { m.playlistId = String(bid.dropFirst(2)); m.kind = .playlist }
            else { m.channelId = bid; m.params = be["params"].string; m.kind = .channel }
        }
        switch contentType {
        case "TILE_CONTENT_TYPE_SHORTS": m.kind = .short
        case "TILE_CONTENT_TYPE_PLAYLIST": if m.kind != .playlist { m.kind = m.videoId != nil && m.playlistId != nil ? .mix : .playlist }
        case "TILE_CONTENT_TYPE_CHANNEL": m.kind = .channel
        default: break
        }
        if m.kind == .channel { m.channelThumbnail = m.thumbnail }
        // channel id for videos: menu -> browseEndpoint
        if m.channelId == nil {
            for b in t.findAll("browseEndpoint") {
                if let id = b["browseId"].string, id.hasPrefix("UC") { m.channelId = id; break }
            }
        }
        feedback(t, into: &m)
        return m
    }

    static func lockup(_ l: JSON) -> MediaItem {
        var m = MediaItem()
        let ct = l["contentType"].string ?? ""
        let id = l["contentId"].string
        let meta = l["metadata"]["lockupMetadataViewModel"]
        m.title = meta["title"].text ?? ""
        let rows = meta["metadata"]["contentMetadataViewModel"]["metadataRows"].array.map { row in
            row["metadataParts"].array.compactMap { $0["text"].text }.joined(separator: " • ")
        }.filter { !$0.isEmpty }
        m.subtitle = rows.first
        if rows.count > 1 { m.info = rows.dropFirst().joined(separator: " • ") }
        let thumbVM = l["contentImage"]["thumbnailViewModel"].exists ? l["contentImage"]["thumbnailViewModel"]
            : l["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]
        m.thumbnail = thumbVM["image"].bestThumbnail ?? l["contentImage"].first("image").bestThumbnail
        m.channelThumbnail = meta["image"].first("image").bestThumbnail
        for badge in l["contentImage"].findAll("thumbnailBadgeViewModel") {
            let txt = badge["text"].string ?? ""
            let style = badge["badgeStyle"].string ?? ""
            if style.contains("LIVE") || txt == "LIVE" { m.kind = .live }
            else if txt.contains(":") { m.duration = txt; m.durationSeconds = parseDuration(txt) }
            else if !txt.isEmpty { m.badges.append(txt) }
        }
        if let p = l["contentImage"].first("thumbnailOverlayProgressBarViewModel")["startPercent"].double { m.watchedPercent = p }
        switch ct {
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST":
            m.kind = .playlist; m.playlistId = id
        case "LOCKUP_CONTENT_TYPE_ALBUM":
            m.kind = .playlist; m.playlistId = id
        case "LOCKUP_CONTENT_TYPE_CHANNEL":
            m.kind = .channel; m.channelId = id; m.channelThumbnail = m.thumbnail
        default:
            m.videoId = id
            if m.kind != .live { m.kind = .video }
        }
        if let we = l.first("watchEndpoint").exists ? l.first("watchEndpoint") : nil {
            if m.videoId == nil { m.videoId = we["videoId"].string }
            if m.kind == .playlist, we["videoId"].string != nil, (m.playlistId ?? "").hasPrefix("RD") { m.kind = .mix; m.videoId = we["videoId"].string }
        }
        for b in l.findAll("browseEndpoint") {
            if let bid = b["browseId"].string, bid.hasPrefix("UC") { m.channelId = m.channelId ?? bid; break }
        }
        m.clickTracking = l.first("clickTrackingParams").string
        feedback(l, into: &m)
        return m
    }

    static func shortsLockup(_ s: JSON) -> MediaItem {
        var m = MediaItem()
        m.kind = .short
        m.videoId = s.first("reelWatchEndpoint")["videoId"].string
            ?? s["entityId"].string?.replacingOccurrences(of: "shorts-shelf-item-", with: "")
        m.title = s["overlayMetadata"]["primaryText"]["content"].string ?? s["accessibilityText"].string ?? ""
        m.info = s["overlayMetadata"]["secondaryText"]["content"].string
        m.thumbnail = s["thumbnail"].bestThumbnail ?? s.first("thumbnail").bestThumbnail
        return m
    }

    static func reel(_ r: JSON) -> MediaItem {
        var m = MediaItem()
        m.kind = .short
        m.videoId = r["videoId"].string
        m.title = r["headline"].text ?? ""
        m.info = r["viewCountText"].text
        m.thumbnail = r["thumbnail"].bestThumbnail
        return m
    }

    static func webVideo(_ v: JSON) -> MediaItem {
        var m = MediaItem()
        m.videoId = v["videoId"].string
        m.title = v["title"].text ?? v["headline"].text ?? ""
        m.subtitle = (v["shortBylineText"].text ?? v["longBylineText"].text ?? v["ownerText"].text)
        let views = v["shortViewCountText"].text ?? v["viewCountText"].text
        let date = v["publishedTimeText"].text
        m.info = [views, date].compactMap { $0 }.joined(separator: " • ")
        m.duration = v["lengthText"].text ?? v["thumbnailOverlays"].first("thumbnailOverlayTimeStatusRenderer")["text"].text
        if let d = m.duration { m.durationSeconds = parseDuration(d) }
        if let s = v["lengthSeconds"].int { m.durationSeconds = s }
        m.thumbnail = v["thumbnail"].bestThumbnail
        m.channelThumbnail = v["channelThumbnail"].first("thumbnails").exists
            ? JSON.object(["thumbnails": v["channelThumbnail"].first("thumbnails")]).bestThumbnail : nil
        m.playlistId = v["navigationEndpoint"]["watchEndpoint"]["playlistId"].string
        m.playlistIndex = v["navigationEndpoint"]["watchEndpoint"]["index"].int ?? v["index"].text.flatMap { Int($0) }.map { $0 - 1 }
        m.channelId = v.first("browseEndpoint")["browseId"].string
        if let p = v.first("thumbnailOverlayResumePlaybackRenderer")["percentDurationWatched"].double { m.watchedPercent = p }
        for b in v["badges"].array { if let l = b["metadataBadgeRenderer"]["label"].string { m.badges.append(l) } }
        let style = v.first("thumbnailOverlayTimeStatusRenderer")["style"].string
        if style == "LIVE" || m.badges.contains("LIVE") { m.kind = .live }
        if style == "UPCOMING" || v["upcomingEventData"].exists { m.kind = .upcoming }
        if style == "SHORTS" { m.kind = .short }
        m.clickTracking = v["navigationEndpoint"]["clickTrackingParams"].string
        feedback(v, into: &m)
        return m
    }

    static func channel(_ c: JSON) -> MediaItem {
        var m = MediaItem()
        m.kind = .channel
        m.channelId = c["channelId"].string
        m.title = c["title"].text ?? ""
        m.subtitle = c["subscriberCountText"].text ?? c["videoCountText"].text
        m.info = c["videoCountText"].text
        m.thumbnail = c["thumbnail"].bestThumbnail
        if let t = m.thumbnail, t.absoluteString.hasPrefix("//") { m.thumbnail = URL(string: "https:" + t.absoluteString) }
        m.channelThumbnail = m.thumbnail
        return m
    }

    static func playlist(_ p: JSON) -> MediaItem {
        var m = MediaItem()
        m.kind = .playlist
        m.playlistId = p["playlistId"].string
        m.title = p["title"].text ?? ""
        m.subtitle = p["shortBylineText"].text ?? p["longBylineText"].text
        m.info = p["videoCountText"].text ?? p["videoCountShortText"].text ?? p["videoCount"].string.map { "\($0) videos" }
        m.thumbnail = p["thumbnail"].bestThumbnail ?? p["thumbnails"][0].bestThumbnail ?? p["thumbnailRenderer"].first("thumbnail").bestThumbnail
        if let vid = p["navigationEndpoint"]["watchEndpoint"]["videoId"].string {
            m.videoId = vid
            if (m.playlistId ?? "").hasPrefix("RD") { m.kind = .mix }
        }
        return m
    }

    /// Extracts "Not interested" / "Don't recommend channel" feedback tokens from item menus.
    static func feedback(_ r: JSON, into m: inout MediaItem) {
        for f in r.findAll("feedbackEndpoint") {
            guard let token = f["feedbackToken"].string else { continue }
            if !m.feedbackTokens.values.contains(token) { m.feedbackTokens["feedback\(m.feedbackTokens.count)"] = token }
        }
        for item in r.findAll("menuServiceItemRenderer") {
            guard let text = item["text"].text, let token = item.first("feedbackToken").string else { continue }
            m.feedbackTokens[text] = token
        }
    }

    // MARK: Shelves / pages

    static func shelfTitle(_ s: JSON) -> String {
        let h = s["headerRenderer"]["shelfHeaderRenderer"]
        return h["title"].text
            ?? h["avatarLockup"]["avatarLockupRenderer"]["title"].text
            ?? s["title"].text
            ?? s["header"].first("title").text
            ?? s["headerRenderer"].first("title").text
            ?? ""
    }

    static func continuationToken(_ j: JSON) -> String? {
        j.first("nextContinuationData")["continuation"].string
            ?? j.first("continuationCommand")["token"].string
            ?? j.first("reloadContinuationData")["continuation"].string
    }

    /// Parses a browse/search/continuation response into shelves.
    static func page(_ resp: JSON) -> BrowsePage {
        var page = BrowsePage()
        var shelves: [Shelf] = []
        let shelfKeys = ["shelfRenderer", "reelShelfRenderer", "richShelfRenderer", "horizontalCardListRenderer", "gridShelfViewModel"]

        func walk(_ j: JSON) {
            switch j {
            case .object(let d):
                for key in shelfKeys {
                    if let s = d[key] {
                        let items = items(in: s["content"].exists ? s["content"] : (s["items"].exists ? s["items"] : s["contents"]))
                        if !items.isEmpty {
                            let ep = s["endpoint"]["browseEndpoint"].exists ? s["endpoint"]["browseEndpoint"]
                                : s.first("browseEndpoint")
                            shelves.append(Shelf(title: shelfTitle(s), items: items,
                                                 continuation: s["content"]["horizontalListRenderer"]["continuations"].exists
                                                    ? continuationToken(s["content"]["horizontalListRenderer"]["continuations"]) : nil,
                                                 browseId: ep["browseId"].string, browseParams: ep["params"].string))
                        }
                        return
                    }
                }
                for (k, v) in d where k != "engagementPanels" && k != "frameworkUpdates" && k != "header" { walk(v) }
            case .array(let a):
                for v in a { walk(v) }
            default: break
            }
        }

        let roots: [JSON] = [resp["contents"], resp["continuationContents"], resp["onResponseReceivedActions"],
                             resp["onResponseReceivedCommands"], resp["onResponseReceivedEndpoints"]]
        for r in roots where r.exists { walk(r) }

        // Items not inside a shelf (grids, search results, continuations) => one unnamed shelf
        var loose: [MediaItem] = []
        let inShelves = Set(shelves.flatMap { $0.items.map(\.id) })
        for r in roots where r.exists {
            for m in items(in: r) where !inShelves.contains(m.id) { loose.append(m) }
        }
        if !loose.isEmpty { shelves.append(Shelf(title: "", items: loose)) }

        page.shelves = shelves

        // top-level continuation (sectionList / grid), not per-shelf horizontal list
        let cc = resp["continuationContents"]
        if cc.exists {
            for (_, v) in cc.object {
                if let t = continuationToken(v["continuations"]) { page.continuation = t }
            }
        }
        if page.continuation == nil {
            for sl in resp["contents"].findAll("sectionListRenderer") + resp["contents"].findAll("gridRenderer") {
                if let t = continuationToken(sl["continuations"]) { page.continuation = t; break }
            }
        }
        if page.continuation == nil {
            for key in ["onResponseReceivedActions", "onResponseReceivedCommands", "onResponseReceivedEndpoints", "contents"] {
                if let ci = resp[key].findAll("continuationItemRenderer").last, let t = ci.first("token").string { page.continuation = t; break }
            }
        }

        // Channel header + tabs
        let header = resp["contents"].first("channelHeaderRenderer").exists ? resp["contents"].first("channelHeaderRenderer")
            : resp["header"].first("c4TabbedHeaderRenderer").exists ? resp["header"].first("c4TabbedHeaderRenderer")
            : resp["header"].first("pageHeaderViewModel")
        if header.exists {
            let sub = header.first("subscribeButtonRenderer")
            page.header = ChannelHeader(
                channelId: sub["channelId"].string ?? header["channelId"].string ?? "",
                title: header["title"].text ?? header["pageTitle"].string ?? "",
                subtitle: header["subtitle"].first("text").text ?? header["subscriberCountText"].text,
                avatar: header["avatar"].bestThumbnail ?? header["image"].first("image").bestThumbnail,
                banner: header["backgroundImage"].bestThumbnail ?? header["banner"].bestThumbnail ?? header["banner"].first("image").bestThumbnail,
                subscribed: sub["subscribed"].bool,
                subscribeParams: sub.first("subscribeEndpoint")["params"].string)
        }
        // TV channel: shelves with browse endpoints act as tabs
        for s in shelves where s.browseId != nil && s.browseParams != nil && !s.title.isEmpty {
            page.tabs.append(ChannelTab(title: s.title, browseId: s.browseId!, params: s.browseParams))
        }
        for tab in resp["contents"].findAll("tabRenderer") {
            let be = tab["endpoint"]["browseEndpoint"]
            guard let title = tab["title"].string, let bid = be["browseId"].string else { continue }
            if !page.tabs.contains(where: { $0.title == title }) {
                page.tabs.append(ChannelTab(title: title, browseId: bid, params: be["params"].string))
            }
        }
        return page
    }

    static func parseDuration(_ s: String) -> Int? {
        let parts = s.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, parts.count == s.split(separator: ":").count else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
