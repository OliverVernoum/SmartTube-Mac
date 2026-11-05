import Foundation

enum ItemKind: String, Codable {
    case video, short, live, upcoming, playlist, channel, mix, unknown
}

/// Any card shown in a grid: video, channel, playlist...
struct MediaItem: Identifiable, Hashable, Codable {
    var id: String { (videoId ?? playlistId ?? channelId ?? title) + "|" + kind.rawValue + "|" + (params ?? "") }
    var kind: ItemKind = .video
    var videoId: String?
    var playlistId: String?
    var playlistIndex: Int?
    var channelId: String?
    var params: String?
    var title: String = ""
    var subtitle: String?          // channel name
    var info: String?              // "1M views • 2 years ago"
    var duration: String?
    var durationSeconds: Int?
    var thumbnail: URL?
    var channelThumbnail: URL?
    var badges: [String] = []
    var watchedPercent: Double?    // 0...100
    var startSeconds: Double?
    var clickTracking: String?
    /// For a "feedback" menu: not interested / dont recommend channel tokens
    var feedbackTokens: [String: String] = [:]
    var isUpcoming: Bool { kind == .upcoming }
    var isLive: Bool { kind == .live }

    static func video(_ id: String, title: String = "", channel: String? = nil) -> MediaItem {
        var m = MediaItem()
        m.videoId = id; m.title = title; m.subtitle = channel
        m.thumbnail = URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        return m
    }
}

struct Shelf: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var items: [MediaItem]
    var continuation: String?
    /// Endpoint to open the full section ("View all")
    var browseId: String?
    var browseParams: String?
}

/// A browsable page: list of shelves (rows) or a single grid with continuation.
struct BrowsePage {
    var title: String?
    var shelves: [Shelf] = []
    var continuation: String?
    var tabs: [ChannelTab] = []
    var header: ChannelHeader?

    var allItems: [MediaItem] { shelves.flatMap(\.items) }
}

struct ChannelTab: Identifiable, Hashable {
    var id: String { title + (params ?? "") }
    var title: String
    var browseId: String
    var params: String?
}

struct ChannelHeader: Hashable {
    var channelId: String
    var title: String
    var subtitle: String?
    var avatar: URL?
    var banner: URL?
    var subscribed: Bool?
    var subscribeParams: String?
}

struct Chapter: Identifiable, Hashable {
    var id: Double { start }
    var title: String
    var start: Double
    var thumbnail: URL?
}

enum LikeStatus: String { case like = "LIKE", dislike = "DISLIKE", none = "INDIFFERENT" }

/// Data from the `next` endpoint (watch page): metadata, related, chapters, like state, etc.
struct VideoDetails {
    var videoId: String
    var title: String = ""
    var description: String = ""
    var channelId: String?
    var channelName: String?
    var channelAvatar: URL?
    var subscriberCount: String?
    var subscribed: Bool = false
    var subscribeParams: String?
    var notificationState: String?
    var viewCount: String?
    var date: String?
    var likeCount: String?
    var likeStatus: LikeStatus = .none
    var dislikeCount: String?
    var chapters: [Chapter] = []
    var related: [Shelf] = []
    var autoplayNext: MediaItem?
    var playlist: PlaylistQueue?
    var commentsToken: String?
    var commentsCount: String?
    var liveChatContinuation: String?
    var isLive: Bool = false
    var relatedContinuation: String?
}

struct PlaylistQueue {
    var playlistId: String
    var title: String
    var items: [MediaItem]
    var currentIndex: Int
}

struct Comment: Identifiable, Hashable {
    var id: String
    var author: String
    var authorThumbnail: URL?
    var authorChannelId: String?
    var text: String
    var published: String?
    var likes: String?
    var isLiked: Bool = false
    var repliesCount: String?
    var repliesToken: String?
    var isPinned: Bool = false
    var isHearted: Bool = false
    var likeAction: String?
    var unlikeAction: String?
}

struct CommentsPage {
    var title: String?
    var comments: [Comment]
    var continuation: String?
    var sortOptions: [SortOption] = []
}

struct SortOption: Hashable {
    var title: String
    var token: String
}

struct ChatMessage: Identifiable, Hashable {
    var id: String
    var author: String
    var authorPhoto: URL?
    var message: String
    var isOwner = false
    var isModerator = false
    var isMember = false
    var superChat: String?
}

struct PlaylistInfo: Identifiable, Hashable {
    var id: String
    var title: String
    var containsVideo: Bool
}

enum AppSection: String, CaseIterable, Identifiable {
    case home, shorts, subscriptions, history, playlists, channels, channelGroups, music, gaming, news, sports, movies, live, trending, notifications, kids, settings
    var id: String { rawValue }

    static let defaultOrder: [AppSection] = [.home, .shorts, .subscriptions, .channels, .history, .playlists, .music, .gaming, .news, .sports, .movies, .live, .notifications]

    var title: String {
        switch self {
        case .home: return "Home"
        case .shorts: return "Shorts"
        case .subscriptions: return "Subscriptions"
        case .history: return "History"
        case .playlists: return "Playlists"
        case .channels: return "Channels"
        case .channelGroups: return "Channel groups"
        case .music: return "Music"
        case .gaming: return "Gaming"
        case .news: return "News"
        case .sports: return "Sports"
        case .movies: return "Movies"
        case .live: return "Live"
        case .trending: return "Trending"
        case .notifications: return "Notifications"
        case .kids: return "Kids"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .shorts: return "bolt.horizontal"
        case .subscriptions: return "rectangle.stack.badge.play"
        case .history: return "clock.arrow.circlepath"
        case .playlists: return "list.and.film"
        case .channels: return "person.2"
        case .channelGroups: return "person.3.sequence"
        case .music: return "music.note"
        case .gaming: return "gamecontroller"
        case .news: return "newspaper"
        case .sports: return "sportscourt"
        case .movies: return "film"
        case .live: return "dot.radiowaves.left.and.right"
        case .trending: return "flame"
        case .notifications: return "bell"
        case .kids: return "figure.and.child.holdinghands"
        case .settings: return "gear"
        }
    }

    var requiresAuth: Bool { [.subscriptions, .history, .playlists, .channels, .notifications].contains(self) }

    var browseId: String? {
        switch self {
        case .home: return "default"
        case .subscriptions: return "FEsubscriptions"
        case .history: return "FEhistory"
        case .playlists: return "FEplaylist_aggregation"
        case .channels: return "FEsubscriptions"
        case .gaming: return "FEtopics_gaming"
        case .news: return "FEtopics_news"
        case .sports: return "FEtopics_sports"
        case .music: return "FEtopics_music"
        case .movies: return "FEtopics_movies"
        case .live: return "FEtopics_live"
        case .trending: return "FEtrending"
        case .kids: return "FEkids_home"
        case .shorts: return "FEshorts"
        default: return nil
        }
    }
}
