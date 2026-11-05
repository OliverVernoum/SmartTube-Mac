import Foundation
import Combine

enum PlaybackMode: Int, CaseIterable, Identifiable {
    case playAll = 0, repeatOne, repeatList, shuffle, pauseAfterEach, stopAfterEach, closeAfterEach
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .playAll: return "Play all (autoplay next)"
        case .repeatOne: return "Repeat video"
        case .repeatList: return "Repeat list"
        case .shuffle: return "Shuffle"
        case .pauseAfterEach: return "Pause after each video"
        case .stopAfterEach: return "Stop after video (go back)"
        case .closeAfterEach: return "List / no autoplay"
        }
    }
}

enum VideoCodecPreference: Int, CaseIterable, Identifiable {
    case auto = 0, avc, av1
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto (AV1 when hardware supports it)"
        case .avc: return "H.264 / AVC (max compatibility)"
        case .av1: return "AV1 (always)"
        }
    }
}

enum SegmentAction: String, CaseIterable, Identifiable, Codable {
    case skip, showToast, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .skip: return "Skip automatically"
        case .showToast: return "Show skip button"
        case .nothing: return "Do nothing"
        }
    }
}

enum SponsorCategory: String, CaseIterable, Identifiable {
    case sponsor, selfpromo, interaction, intro, outro, preview, music_offtopic, filler, poi_highlight, exclusive_access
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sponsor: return "Sponsor"
        case .selfpromo: return "Unpaid/Self Promotion"
        case .interaction: return "Interaction Reminder (Subscribe)"
        case .intro: return "Intermission/Intro Animation"
        case .outro: return "Endcards/Credits"
        case .preview: return "Preview/Recap"
        case .music_offtopic: return "Music: Non-Music Section"
        case .filler: return "Filler Tangent/Jokes"
        case .poi_highlight: return "Highlight"
        case .exclusive_access: return "Exclusive Access"
        }
    }
    var colorHex: String {
        switch self {
        case .sponsor: return "#00D400"
        case .selfpromo: return "#FFFF00"
        case .interaction: return "#CC00FF"
        case .intro: return "#00FFFF"
        case .outro: return "#0202ED"
        case .preview: return "#008FD6"
        case .music_offtopic: return "#FF9900"
        case .filler: return "#7300FF"
        case .poi_highlight: return "#FF1684"
        case .exclusive_access: return "#008A5C"
        }
    }
    var defaultAction: SegmentAction {
        switch self {
        case .sponsor, .selfpromo, .interaction: return .skip
        case .poi_highlight, .exclusive_access, .filler: return .nothing
        default: return .showToast
        }
    }
}

/// App settings, persisted in UserDefaults. Mirrors SmartTube's PlayerData / GeneralData / MainUIData /
/// SponsorBlockData / SearchData / DeArrowData options that make sense on macOS.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    private func get<T>(_ key: String, _ def: T) -> T { (d.object(forKey: key) as? T) ?? def }
    private func set<T>(_ key: String, _ v: T) { objectWillChange.send(); d.set(v, forKey: key) }

    // MARK: Language / region
    var language: String { get { get("language", Locale.current.language.languageCode?.identifier ?? "en") } set { set("language", newValue) } }
    var country: String { get { get("country", Locale.current.region?.identifier ?? "US") } set { set("country", newValue) } }
    var safeSearch: Bool { get { get("safeSearch", false) } set { set("safeSearch", newValue) } }

    // MARK: Player
    var preferredQuality: Int { get { get("preferredQuality", 1080) } set { set("preferredQuality", newValue) } } // max height; 0 = auto
    var codec: VideoCodecPreference { get { VideoCodecPreference(rawValue: get("codec", 0)) ?? .auto } set { set("codec", newValue.rawValue) } }
    var preferHighFPS: Bool { get { get("preferHighFPS", true) } set { set("preferHighFPS", newValue) } }
    var speed: Double { get { get("speed", 1.0) } set { set("speed", newValue) } }
    var rememberSpeedPerChannel: Bool { get { get("speedPerChannel", false) } set { set("speedPerChannel", newValue) } }
    var speedPerVideo: Bool { get { get("speedPerVideo", false) } set { set("speedPerVideo", newValue) } }
    var volume: Double { get { get("volume", 1.0) } set { set("volume", newValue) } }
    var playbackMode: PlaybackMode { get { PlaybackMode(rawValue: get("playbackMode", 0)) ?? .playAll } set { set("playbackMode", newValue.rawValue) } }
    var seekIncrement: Double { get { get("seekIncrement", 10.0) } set { set("seekIncrement", newValue) } }
    var audioLanguage: String { get { get("audioLanguage", "") } set { set("audioLanguage", newValue) } }   // "" = original
    var rememberPosition: Bool { get { get("rememberPosition", true) } set { set("rememberPosition", newValue) } }
    var rememberPositionLive: Bool { get { get("rememberPositionLive", false) } set { set("rememberPositionLive", newValue) } }
    var rememberPositionShorts: Bool { get { get("rememberPositionShorts", false) } set { set("rememberPositionShorts", newValue) } }
    var showClock: Bool { get { get("showClock", false) } set { set("showClock", newValue) } }
    var showRemainingTime: Bool { get { get("showRemaining", true) } set { set("showRemaining", newValue) } }
    var showEndingTime: Bool { get { get("showEndingTime", false) } set { set("showEndingTime", newValue) } }
    var showQualityInfo: Bool { get { get("showQualityInfo", false) } set { set("showQualityInfo", newValue) } }
    var uiHideTimeout: Double { get { get("uiHideTimeout", 3.0) } set { set("uiHideTimeout", newValue) } }
    var sleepTimerMinutes: Int { get { get("sleepTimer", 0) } set { set("sleepTimer", newValue) } }
    var liveChatEnabled: Bool { get { get("liveChat", true) } set { set("liveChat", newValue) } }
    var showLikesCounter: Bool { get { get("likesCounter", true) } set { set("likesCounter", newValue) } }
    var chapterNotifications: Bool { get { get("chapterNotifications", true) } set { set("chapterNotifications", newValue) } }
    var skipShorts: Bool { get { get("skipShorts", false) } set { set("skipShorts", newValue) } }
    var loopShorts: Bool { get { get("loopShorts", true) } set { set("loopShorts", newValue) } }
    var allowAllSpeeds: Bool { get { get("allSpeeds", false) } set { set("allSpeeds", newValue) } }
    var pauseOnSeek: Bool { get { get("pauseOnSeek", false) } set { set("pauseOnSeek", newValue) } }
    var backgroundPlayback: Bool { get { get("backgroundPlayback", false) } set { set("backgroundPlayback", newValue) } }
    var autoPiP: Bool { get { get("autoPiP", false) } set { set("autoPiP", newValue) } }
    var resizeMode: Int { get { get("resizeMode", 0) } set { set("resizeMode", newValue) } } // 0 fit, 1 fill, 2 stretch
    var zoomPercent: Int { get { get("zoom", 100) } set { set("zoom", newValue) } }
    var videoFlip: Bool { get { get("videoFlip", false) } set { set("videoFlip", newValue) } }
    var rotation: Int { get { get("rotation", 0) } set { set("rotation", newValue) } }
    var pitchCorrection: Bool { get { get("pitchCorrection", true) } set { set("pitchCorrection", newValue) } }

    // MARK: Subtitles
    var subtitlesEnabled: Bool { get { get("subsEnabled", false) } set { set("subsEnabled", newValue) } }
    var subtitleLanguage: String { get { get("subsLang", "") } set { set("subsLang", newValue) } }
    var subtitleAutoTranslate: String { get { get("subsTranslate", "") } set { set("subsTranslate", newValue) } }
    var subtitleScale: Double { get { get("subsScale", 1.0) } set { set("subsScale", newValue) } }
    var subtitlePosition: Double { get { get("subsPosition", 0.08) } set { set("subsPosition", newValue) } }
    var subtitleStyle: Int { get { get("subsStyle", 0) } set { set("subsStyle", newValue) } } // 0 white on black, 1 white outline, 2 yellow on black, 3 yellow outline
    var subtitlesPerChannel: Bool { get { get("subsPerChannel", false) } set { set("subsPerChannel", newValue) } }

    // MARK: SponsorBlock
    var sponsorBlockEnabled: Bool { get { get("sbEnabled", true) } set { set("sbEnabled", newValue) } }
    func sponsorAction(_ c: SponsorCategory) -> SegmentAction {
        SegmentAction(rawValue: d.string(forKey: "sbAction.\(c.rawValue)") ?? "") ?? c.defaultAction
    }
    func setSponsorAction(_ c: SponsorCategory, _ a: SegmentAction) { set("sbAction.\(c.rawValue)", a.rawValue) }
    var sponsorShowOnSeekbar: Bool { get { get("sbSeekbar", true) } set { set("sbSeekbar", newValue) } }
    var sponsorSkipOnce: Bool { get { get("sbSkipOnce", true) } set { set("sbSkipOnce", newValue) } }
    var sponsorMinDuration: Double { get { get("sbMinDuration", 0.0) } set { set("sbMinDuration", newValue) } }
    var sponsorExcludedChannels: [String] { get { get("sbExcluded", [String]()) } set { set("sbExcluded", newValue) } }
    var sponsorPaidNotification: Bool { get { get("sbPaidNotify", true) } set { set("sbPaidNotify", newValue) } }

    // MARK: DeArrow / Return YouTube Dislike
    var deArrowTitles: Bool { get { get("deArrowTitles", false) } set { set("deArrowTitles", newValue) } }
    var deArrowThumbnails: Bool { get { get("deArrowThumbs", false) } set { set("deArrowThumbs", newValue) } }
    var returnDislikes: Bool { get { get("ryd", true) } set { set("ryd", newValue) } }

    // MARK: UI / content
    var hideShortsHome: Bool { get { get("hideShortsHome", false) } set { set("hideShortsHome", newValue) } }
    var hideShortsSubscriptions: Bool { get { get("hideShortsSubs", false) } set { set("hideShortsSubs", newValue) } }
    var hideShortsHistory: Bool { get { get("hideShortsHistory", false) } set { set("hideShortsHistory", newValue) } }
    var hideShortsChannel: Bool { get { get("hideShortsChannel", false) } set { set("hideShortsChannel", newValue) } }
    var hideShortsSearch: Bool { get { get("hideShortsSearch", false) } set { set("hideShortsSearch", newValue) } }
    var hideUpcoming: Bool { get { get("hideUpcoming", false) } set { set("hideUpcoming", newValue) } }
    var hideWatched: Bool { get { get("hideWatched", false) } set { set("hideWatched", newValue) } }
    var hideWatchedPercent: Int { get { get("hideWatchedPercent", 90) } set { set("hideWatchedPercent", newValue) } }
    var multilineTitles: Bool { get { get("multilineTitles", true) } set { set("multilineTitles", newValue) } }
    var gridScale: Double { get { get("gridScale", 1.0) } set { set("gridScale", newValue) } }
    var enabledSections: [String] {
        get { get("sections", AppSection.defaultOrder.map(\.rawValue)) }
        set { set("sections", newValue) }
    }
    var startSection: String { get { get("startSection", AppSection.home.rawValue) } set { set("startSection", newValue) } }
    var colorScheme: Int { get { get("colorScheme", 0) } set { set("colorScheme", newValue) } } // 0 system, 1 dark, 2 light
    var accentColor: Int { get { get("accentColor", 0) } set { set("accentColor", newValue) } }
    var blockedChannels: [String: String] { get { get("blockedChannels", [String: String]()) } set { set("blockedChannels", newValue) } }

    // MARK: History / search
    var historyEnabled: Bool { get { get("historyEnabled", true) } set { set("historyEnabled", newValue) } }
    var searchHistoryEnabled: Bool { get { get("searchHistory", true) } set { set("searchHistory", newValue) } }
    var searchHistory: [String] { get { get("searchHistoryList", [String]()) } set { set("searchHistoryList", newValue) } }

    // MARK: Privacy
    var settingsPassword: String { get { get("settingsPassword", "") } set { set("settingsPassword", newValue) } }

    // MARK: Per channel / video memory
    func channelSpeed(_ id: String) -> Double? { (d.dictionary(forKey: "channelSpeeds") as? [String: Double])?[id] }
    func setChannelSpeed(_ id: String, _ v: Double) {
        var m = (d.dictionary(forKey: "channelSpeeds") as? [String: Double]) ?? [:]
        m[id] = v; d.set(m, forKey: "channelSpeeds")
    }
    func videoSpeed(_ id: String) -> Double? { (d.dictionary(forKey: "videoSpeeds") as? [String: Double])?[id] }
    func setVideoSpeed(_ id: String, _ v: Double) {
        var m = (d.dictionary(forKey: "videoSpeeds") as? [String: Double]) ?? [:]
        m[id] = v
        if m.count > 500 { m = Dictionary(uniqueKeysWithValues: Array(m.suffix(400))) }
        d.set(m, forKey: "videoSpeeds")
    }
    func channelSubtitles(_ id: String) -> String? { (d.dictionary(forKey: "channelSubs") as? [String: String])?[id] }
    func setChannelSubtitles(_ id: String, _ lang: String?) {
        var m = (d.dictionary(forKey: "channelSubs") as? [String: String]) ?? [:]
        m[id] = lang; d.set(m, forKey: "channelSubs")
    }

    /// Exports all app settings (for backup).
    func exportBackup() -> Data {
        let dict = d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "SmartTube") ?? [:]
        return (try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)) ?? Data()
    }

    func importBackup(_ data: Data) throws {
        guard let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw APIError.parse("Invalid backup")
        }
        objectWillChange.send()
        for (k, v) in dict { d.set(v, forKey: k) }
    }

    func reset() {
        objectWillChange.send()
        if let id = Bundle.main.bundleIdentifier { d.removePersistentDomain(forName: id) }
    }
}
