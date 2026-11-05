import Foundation

struct ChannelGroup: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var channels: [GroupChannel]
}

struct GroupChannel: Codable, Hashable {
    var channelId: String
    var title: String
    var thumbnail: URL?
}

/// Local channel groups (SmartTube "Channel groups"), with NewPipe / PocketTube / Grayjay import.
@MainActor
final class ChannelGroupStore: ObservableObject {
    static let shared = ChannelGroupStore()
    @Published var groups: [ChannelGroup] = [] { didSet { save() } }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SmartTube", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("channel_groups.json")
    }()

    init() {
        if let d = try? Data(contentsOf: url), let g = try? JSONDecoder().decode([ChannelGroup].self, from: d) { groups = g }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(groups) { try? d.write(to: url, options: .atomic) }
    }

    func add(_ channel: GroupChannel, to groupId: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupId }) else { return }
        if !groups[i].channels.contains(where: { $0.channelId == channel.channelId }) { groups[i].channels.append(channel) }
    }

    func remove(_ channelId: String, from groupId: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[i].channels.removeAll { $0.channelId == channelId }
    }

    func importFile(_ data: Data) throws -> Int {
        let j = try JSON(data: data)
        var imported: [ChannelGroup] = []
        if j["subscriptions"].exists { // NewPipe
            let chans = j["subscriptions"].array.compactMap { s -> GroupChannel? in
                guard let u = s["url"].string, let id = u.components(separatedBy: "/channel/").last, id.hasPrefix("UC") else { return nil }
                return GroupChannel(channelId: id, title: s["name"].string ?? id)
            }
            imported.append(ChannelGroup(title: "NewPipe", channels: chans))
        } else if j["ysc_collection"].exists { // PocketTube
            for (name, v) in j.object where name != "ysc_collection" {
                let ids = v.array.compactMap { $0.string }.filter { $0.hasPrefix("UC") }
                if !ids.isEmpty { imported.append(ChannelGroup(title: name, channels: ids.map { GroupChannel(channelId: $0, title: $0) })) }
            }
        } else if !j.array.isEmpty || j["urls"].exists { // Grayjay (array of groups or single)
            let list = j.array.isEmpty ? [j] : j.array
            for g in list {
                let chans = g["urls"].array.compactMap { u -> GroupChannel? in
                    guard let s = u.string, let id = s.components(separatedBy: "/channel/").last, id.hasPrefix("UC") else { return nil }
                    return GroupChannel(channelId: id, title: id)
                }
                imported.append(ChannelGroup(title: g["name"].string ?? "Grayjay", channels: chans))
            }
        } else {
            throw APIError.parse("Unknown channel groups format")
        }
        groups.append(contentsOf: imported.filter { !$0.channels.isEmpty })
        return imported.reduce(0) { $0 + $1.channels.count }
    }

    /// Combined feed: latest uploads of each channel, interleaved.
    static func feed(_ group: ChannelGroup) async -> [MediaItem] {
        var lists: [[MediaItem]] = []
        await withTaskGroup(of: [MediaItem].self) { tg in
            for c in group.channels.prefix(40) {
                tg.addTask {
                    let p = try? await YouTubeService.channel(c.channelId, section: .videos)
                    return Array((p?.allItems ?? []).filter { $0.videoId != nil }.prefix(10))
                }
            }
            for await l in tg { lists.append(l) }
        }
        var out: [MediaItem] = []
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen { for l in lists where i < l.count { out.append(l[i]) } }
        return out
    }
}
