import Foundation
import AVFoundation

/// Turns YouTube DASH (fragmented MP4 + sidx) formats into an in-memory HLS presentation that
/// AVPlayer can play natively (byte-range segments pointing at googlevideo).
/// Plays the role of SmartTube's mpdbuilder/hlsbuilder.
final class HLSBuilder {
    struct Selection {
        var maxHeight: Int?        // nil = no limit
        var exactVideoItag: Int?   // force one variant
        var preferAV1: Bool
        var audioOnly = false
    }

    let info: StreamInfo
    let selection: Selection
    private(set) var videoVariants: [StreamFormat] = []
    private(set) var audioTracks: [StreamFormat] = []

    init(info: StreamInfo, selection: Selection) {
        self.info = info
        self.selection = selection
        choose()
    }

    private func choose() {
        let mp4Video = info.videoFormats.filter { $0.isMP4 && $0.indexRange != nil && $0.initRange != nil && ($0.isAVC || $0.isAV1) }
        var video = mp4Video.filter { selection.preferAV1 ? true : $0.isAVC }
        if selection.preferAV1 {
            // keep AV1 where available for a resolution, else AVC
            var byHeight: [Int: [StreamFormat]] = [:]
            for f in video { byHeight[f.height ?? 0, default: []].append(f) }
            video = byHeight.values.flatMap { list -> [StreamFormat] in
                let av1 = list.filter(\.isAV1)
                return av1.isEmpty ? list : av1
            }
        }
        if video.isEmpty { video = mp4Video }
        if let maxH = selection.maxHeight, maxH > 0 {
            let limited = video.filter { ($0.height ?? 0) <= maxH }
            if !limited.isEmpty { video = limited }
        }
        if !Settings.shared.preferHighFPS {
            let lowFps = video.filter { ($0.fps ?? 30) <= 30 }
            if !lowFps.isEmpty { video = lowFps }
        }
        if let itag = selection.exactVideoItag, let f = mp4Video.first(where: { $0.itag == itag }) {
            video = [f]
        }
        // one variant per (height, fps, codec): highest bitrate
        var unique: [String: StreamFormat] = [:]
        for f in video {
            let key = "\(f.height ?? 0)-\(f.fps ?? 0)-\(f.isAV1)-\(f.isHDR)"
            if let e = unique[key], e.bitrate >= f.bitrate { continue }
            unique[key] = f
        }
        videoVariants = unique.values.sorted { ($0.height ?? 0, $0.bitrate) > ($1.height ?? 0, $1.bitrate) }

        let aac = info.audioFormats.filter { $0.isMP4 && $0.codecs.hasPrefix("mp4a") && $0.indexRange != nil && $0.initRange != nil }
        var tracks: [String: StreamFormat] = [:]
        for f in aac {
            let key = f.audioTrackId ?? "default"
            if let e = tracks[key] {
                // prefer non-DRC, then higher bitrate (AAC-LC 140 over HE-AAC 139)
                if e.isDRC == f.isDRC && e.bitrate >= f.bitrate { continue }
                if !e.isDRC && f.isDRC { continue }
            }
            tracks[key] = f
        }
        audioTracks = tracks.values.sorted { a, b in
            if a.audioIsDefault != b.audioIsDefault { return a.audioIsDefault }
            return (a.audioTrackName ?? "") < (b.audioTrackName ?? "")
        }
    }

    var isPlayable: Bool { !audioTracks.isEmpty && (selection.audioOnly || !videoVariants.isEmpty) }

    func masterPlaylist(base: String) -> String {
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        let preferredLang = Settings.shared.audioLanguage
        let defaultIdx = audioTracks.firstIndex { !preferredLang.isEmpty && ($0.audioLanguage ?? "").hasPrefix(preferredLang) }
            ?? audioTracks.firstIndex { $0.audioIsDefault } ?? 0
        let audioCodec = audioTracks.first?.codecs ?? "mp4a.40.2"
        for (i, a) in audioTracks.enumerated() {
            let name = (a.audioTrackName ?? "Audio").replacingOccurrences(of: "\"", with: "'")
            let lang = a.audioLanguage.map { ",LANGUAGE=\"\($0)\"" } ?? ""
            s += "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"\(name.isEmpty ? "Audio \(i + 1)" : name)\"\(lang),DEFAULT=\(i == defaultIdx ? "YES" : "NO"),AUTOSELECT=YES,CHANNELS=\"2\",URI=\"\(base)/a/\(i).m3u8\"\n"
        }
        if selection.audioOnly {
            let a = audioTracks[defaultIdx]
            s += "#EXT-X-STREAM-INF:BANDWIDTH=\(max(a.bitrate, 1)),CODECS=\"\(audioCodec)\",AUDIO=\"aud\"\n\(base)/a/\(defaultIdx).m3u8\n"
            return s
        }
        for (i, v) in videoVariants.enumerated() {
            let bw = v.bitrate + (audioTracks.first?.bitrate ?? 128000)
            var attrs = "BANDWIDTH=\(bw),CODECS=\"\(v.codecs),\(audioCodec)\",AUDIO=\"aud\""
            if let w = v.width, let h = v.height { attrs += ",RESOLUTION=\(w)x\(h)" }
            if let fps = v.fps { attrs += ",FRAME-RATE=\(fps).000" }
            if v.isHDR { attrs += ",VIDEO-RANGE=PQ" }
            s += "#EXT-X-STREAM-INF:\(attrs)\n\(base)/v/\(i).m3u8\n"
        }
        return s
    }

    /// Media playlist for a single format (fetches and parses its sidx index).
    func mediaPlaylist(for f: StreamFormat) async throws -> String {
        guard let initR = f.initRange, let indexR = f.indexRange else { throw APIError.other("No index for itag \(f.itag)") }
        let sidxData = try await HTTP.shared.range(f.url, from: indexR.lowerBound, to: indexR.upperBound)
        let refs = try SIDX.parse(sidxData, boxStart: indexR.lowerBound)
        let target = Int(ceil(refs.map(\.duration).max() ?? 10))
        let url = f.url.absoluteString
        var s = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        s += "#EXT-X-MAP:URI=\"\(url)\",BYTERANGE=\"\(initR.upperBound - initR.lowerBound + 1)@\(initR.lowerBound)\"\n"
        for r in refs {
            s += String(format: "#EXTINF:%.6f,\n", r.duration)
            s += "#EXT-X-BYTERANGE:\(r.size)@\(r.offset)\n\(url)\n"
        }
        s += "#EXT-X-ENDLIST\n"
        return s
    }
}

/// Minimal ISO-BMFF 'sidx' parser.
enum SIDX {
    struct Ref { let offset: Int64; let size: Int64; let duration: Double }

    static func parse(_ d: Data, boxStart: Int64) throws -> [Ref] {
        let b = [UInt8](d)
        var p = 0
        func u32() throws -> UInt64 {
            guard p + 4 <= b.count else { throw APIError.parse("sidx truncated") }
            defer { p += 4 }
            return UInt64(b[p]) << 24 | UInt64(b[p + 1]) << 16 | UInt64(b[p + 2]) << 8 | UInt64(b[p + 3])
        }
        func u64() throws -> UInt64 { let hi = try u32(); let lo = try u32(); return hi << 32 | lo }
        // find the sidx box (indexRange normally starts exactly at it)
        while p + 8 <= b.count {
            let size = Int(try u32())
            let type = String(bytes: b[p..<p + 4], encoding: .ascii) ?? ""
            p += 4
            if type == "sidx" { break }
            guard size >= 8 else { throw APIError.parse("bad box") }
            p += size - 8
        }
        let boxBegin = p - 8
        let boxSize: Int64
        do {
            let save = p; p = boxBegin; boxSize = Int64(try u32()); p = save
        }
        let versionFlags = try u32()
        let version = versionFlags >> 24
        _ = try u32() // reference_ID
        let timescale = Double(try u32())
        let firstOffset: UInt64
        if version == 0 { _ = try u32(); firstOffset = try u32() } else { _ = try u64(); firstOffset = try u64() }
        p += 2 // reserved
        guard p + 2 <= b.count else { throw APIError.parse("sidx truncated") }
        let count = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
        var offset = boxStart + Int64(boxBegin) + boxSize + Int64(firstOffset)
        var refs: [Ref] = []
        for _ in 0..<count {
            let typeSize = try u32()
            let size = Int64(typeSize & 0x7FFF_FFFF)
            let dur = Double(try u32()) / max(timescale, 1)
            _ = try u32()
            refs.append(Ref(offset: offset, size: size, duration: dur))
            offset += size
        }
        guard !refs.isEmpty else { throw APIError.parse("empty sidx") }
        return refs
    }
}

/// Serves the generated playlists to AVPlayer through a custom URL scheme.
final class HLSResourceLoader: NSObject, AVAssetResourceLoaderDelegate {
    static let scheme = "stube"
    let builder: HLSBuilder
    let base: String
    private var cache: [String: Data] = [:]
    private let lock = NSLock()
    let queue = DispatchQueue(label: "smarttube.hls.loader")

    init(builder: HLSBuilder) {
        self.builder = builder
        self.base = "\(Self.scheme)://\(UUID().uuidString)"
        super.init()
    }

    var masterURL: URL { URL(string: "\(base)/master.m3u8")! }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme else { return false }
        let path = url.path
        Task {
            do {
                let data = try await self.playlist(for: path)
                loadingRequest.dataRequest?.respond(with: data)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    private func cached(_ key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return cache[key] }
    private func store(_ key: String, _ d: Data) { lock.lock(); cache[key] = d; lock.unlock() }

    private func playlist(for path: String) async throws -> Data {
        if let c = cached(path) { return c }
        let comps = path.split(separator: "/").map(String.init)
        let text: String
        if path.hasSuffix("master.m3u8") {
            text = builder.masterPlaylist(base: base)
        } else if comps.count == 2, let idx = Int(comps[1].replacingOccurrences(of: ".m3u8", with: "")) {
            let f = comps[0] == "v" ? builder.videoVariants[idx] : builder.audioTracks[idx]
            text = try await builder.mediaPlaylist(for: f)
        } else {
            throw APIError.other("Unknown playlist \(path)")
        }
        let d = Data(text.utf8)
        store(path, d)
        return d
    }
}
