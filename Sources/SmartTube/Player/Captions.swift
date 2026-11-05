import Foundation

struct Cue: Hashable {
    let start: Double
    let end: Double
    let text: String
}

enum Captions {
    static func load(_ track: CaptionTrack, translateTo: String? = nil) async throws -> [Cue] {
        var url = track.baseURL.settingQuery("fmt", "json3")
        if let t = translateTo, !t.isEmpty { url = url.settingQuery("tlang", t) }
        let j = try await HTTP.shared.json(url, headers: ["User-Agent": InnerTubeClient.uaWeb])
        var cues: [Cue] = []
        for e in j["events"].array {
            guard let segs = e["segs"].exists ? e["segs"].array : nil, let t = e["tStartMs"].double else { continue }
            let text = segs.compactMap { $0["utf8"].string }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let dur = e["dDurationMs"].double ?? 2000
            cues.append(Cue(start: t / 1000, end: (t + dur) / 1000, text: text))
        }
        // auto-generated tracks overlap word-by-word windows: clip each cue at the next start
        if track.kind == "asr" {
            for i in cues.indices.dropLast() where cues[i].end > cues[i + 1].start {
                cues[i] = Cue(start: cues[i].start, end: max(cues[i].start + 0.3, cues[i + 1].start), text: cues[i].text)
            }
        }
        return cues
    }

    /// Text visible at time t (binary search).
    static func text(at t: Double, in cues: [Cue]) -> String? {
        var lo = 0, hi = cues.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let i = found else { return nil }
        var lines: [String] = []
        var k = i
        while k >= 0 && k >= i - 2 {
            if cues[k].start <= t && t < cues[k].end { lines.insert(cues[k].text, at: 0) }
            k -= 1
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}
