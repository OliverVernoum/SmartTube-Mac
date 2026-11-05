import XCTest
@testable import SmartTube

/// Parser tests against real InnerTube (TV client) responses captured while porting.
final class ParserTests: XCTestCase {
    func fixture(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try JSON(data: Data(contentsOf: url))
    }

    func testChannelPage() throws {
        let page = Parser.page(try fixture("channel"))
        XCTAssertGreaterThan(page.shelves.count, 5)
        let items = page.allItems
        XCTAssertGreaterThan(items.count, 50)
        XCTAssertTrue(items.contains { $0.kind == .video && $0.videoId != nil && !$0.title.isEmpty && $0.duration != nil })
        XCTAssertTrue(items.contains { $0.kind == .short })
        XCTAssertTrue(items.contains { $0.kind == .playlist && $0.playlistId != nil })
        XCTAssertEqual(page.header?.title, "Marques Brownlee")
        XCTAssertTrue(page.tabs.contains { $0.title == "Videos" })
        XCTAssertNotNil(page.shelves.first { !$0.title.isEmpty })
    }

    func testSearch() throws {
        let page = Parser.page(try fixture("search"))
        let items = page.allItems
        XCTAssertGreaterThan(items.count, 20)
        XCTAssertTrue(items.allSatisfy { !$0.title.isEmpty || $0.kind == .short })
        XCTAssertTrue(items.contains { $0.kind == .live })
        XCTAssertNotNil(items.first { $0.videoId != nil }?.thumbnail)
    }

    func testWatchNext() throws {
        let d = YouTubeService.parseDetails(try fixture("next"), videoId: "aqz-KE-bpKQ")
        XCTAssertTrue(d.title.contains("Big Buck Bunny"))
        XCTAssertEqual(d.channelId, "UCSMOQeBJ2RAnuFungnQOxLg")
        XCTAssertEqual(d.channelName, "Blender")
        XCTAssertNotNil(d.commentsToken)
        XCTAssertNotNil(d.likeCount)
        XCTAssertFalse(d.related.flatMap(\.items).isEmpty)
        XCTAssertNotNil(d.autoplayNext?.videoId)
        XCTAssertFalse(d.description.isEmpty)
    }

    func testComments() throws {
        let j = try fixture("comments")
        var comments: [Comment] = []
        for th in j.findAll("commentThreadRenderer") {
            if let c = YouTubeService.parseComment(th["comment"]["commentRenderer"]) { comments.append(c) }
        }
        XCTAssertGreaterThan(comments.count, 5)
        XCTAssertTrue(comments.allSatisfy { !$0.text.isEmpty && !$0.author.isEmpty })
    }

    func testDuration() {
        XCTAssertEqual(Parser.parseDuration("27:24"), 1644)
        XCTAssertEqual(Parser.parseDuration("1:02:03"), 3723)
        XCTAssertNil(Parser.parseDuration("LIVE"))
    }

    func testSearchFilterParams() {
        var f = SearchFilters()
        XCTAssertNil(f.params)
        f.sort = .date
        XCTAssertEqual(f.params, "CAI=")
        f = SearchFilters(); f.uploadDate = .today
        XCTAssertEqual(f.params, "EgIIAg==")
        f = SearchFilters(); f.fourK = true
        XCTAssertEqual(f.params, "EgJwAQ==")
    }

    func testStoryboardSpec() throws {
        let sb = PlayerService.parseStoryboard(try fixture("player")["storyboards"])
        let s = try XCTUnwrap(sb)
        XCTAssertGreaterThan(s.count, 0)
        XCTAssertNotNil(s.frame(at: 30, duration: 600))
    }
}

final class SIDXTests: XCTestCase {
    func testParseVersion0() throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
        // box header: size placeholder
        u32(0); d.append(contentsOf: Array("sidx".utf8))
        u32(0)            // version 0, flags
        u32(1)            // reference id
        u32(1000)         // timescale
        u32(0)            // earliest pts
        u32(0)            // first offset
        u16(0); u16(2)    // reserved, count
        u32(500); u32(5000); u32(0x9000_0000)
        u32(700); u32(4000); u32(0x9000_0000)
        let size = UInt32(d.count)
        d.replaceSubrange(0..<4, with: withUnsafeBytes(of: size.bigEndian) { Data($0) })
        let refs = try SIDX.parse(d, boxStart: 1000)
        XCTAssertEqual(refs.count, 2)
        XCTAssertEqual(refs[0].offset, 1000 + Int64(size))
        XCTAssertEqual(refs[0].size, 500)
        XCTAssertEqual(refs[0].duration, 5.0, accuracy: 0.001)
        XCTAssertEqual(refs[1].offset, 1000 + Int64(size) + 500)
        XCTAssertEqual(refs[1].duration, 4.0, accuracy: 0.001)
    }
}

final class HLSTests: XCTestCase {
    func format(_ itag: Int, _ mime: String, _ codecs: String, h: Int? = nil, br: Int, track: String? = nil, def: Bool = true) -> StreamFormat {
        StreamFormat(itag: itag, url: URL(string: "https://example.invalid/vp?itag=\(itag)")!, mimeType: mime, codecs: codecs,
                     width: h.map { $0 * 16 / 9 }, height: h, fps: h == nil ? nil : 30, bitrate: br, contentLength: 1_000_000,
                     initRange: 0...700, indexRange: 701...1500, qualityLabel: h.map { "\($0)p" },
                     audioTrackId: track, audioTrackName: track, audioIsDefault: def, audioLanguage: track?.components(separatedBy: ".").first, isDRC: false)
    }

    func testMasterPlaylist() {
        let info = StreamInfo(videoId: "x", title: "", author: "", channelId: nil, lengthSeconds: 60, isLive: false, isLiveContent: false,
                              isUpcoming: false, isShort: false, thumbnail: nil,
                              formats: [format(137, "video/mp4", "avc1.640028", h: 1080, br: 4_000_000),
                                        format(136, "video/mp4", "avc1.4d401f", h: 720, br: 2_000_000),
                                        format(248, "video/webm", "vp9", h: 1080, br: 3_000_000),
                                        format(140, "audio/mp4", "mp4a.40.2", br: 130_000, track: "en.4", def: true),
                                        format(140, "audio/mp4", "mp4a.40.2", br: 130_000, track: "de.3", def: false)],
                              hlsURL: nil, captions: [], translationLanguages: [], storyboard: nil, playbackURL: nil, watchtimeURL: nil,
                              cpn: "c", expires: Date(), client: "TVHTML5")
        let b = HLSBuilder(info: info, selection: .init(maxHeight: nil, exactVideoItag: nil, preferAV1: false))
        XCTAssertEqual(b.videoVariants.map(\.itag), [137, 136])
        XCTAssertEqual(b.audioTracks.count, 2)
        let m = b.masterPlaylist(base: "stube://t")
        XCTAssertTrue(m.contains("RESOLUTION=1920x1080"))
        XCTAssertTrue(m.contains("CODECS=\"avc1.640028,mp4a.40.2\""))
        XCTAssertTrue(m.contains("TYPE=AUDIO"))
        XCTAssertEqual(m.components(separatedBy: "#EXT-X-STREAM-INF").count - 1, 2)

        let limited = HLSBuilder(info: info, selection: .init(maxHeight: 720, exactVideoItag: nil, preferAV1: false))
        XCTAssertEqual(limited.videoVariants.map(\.itag), [136])
    }
}
