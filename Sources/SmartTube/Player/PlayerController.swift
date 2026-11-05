import Foundation
import AVFoundation
import AVKit
import Combine
import MediaPlayer

struct QualityOption: Identifiable, Hashable {
    var id: String { "\(itag ?? -1)-\(maxHeight ?? -1)" }
    let title: String
    let itag: Int?
    let maxHeight: Int?
}

@MainActor
final class PlayerController: ObservableObject {
    static let shared = PlayerController()

    let player = AVPlayer()

    @Published var item: MediaItem?
    @Published var info: StreamInfo?
    @Published var details: VideoDetails?
    @Published var isVisible = false
    @Published var isMinimized = false
    @Published var isLoading = false
    @Published var error: String?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var bufferedTime: Double = 0
    @Published var speed: Double = Settings.shared.speed
    @Published var qualityOptions: [QualityOption] = []
    @Published var selectedQuality: QualityOption?
    @Published var currentVideoFormat: String = ""
    @Published var audioOptions: [AVMediaSelectionOption] = []
    @Published var selectedAudio: AVMediaSelectionOption?
    @Published var captionTracks: [CaptionTrack] = []
    @Published var selectedCaption: CaptionTrack?
    @Published var captionTranslation: String = Settings.shared.subtitleAutoTranslate
    @Published var captionText: String?
    @Published var segments: [SponsorSegment] = []
    @Published var skipPrompt: SponsorSegment?
    @Published var toast: String?
    @Published var currentChapter: Chapter?
    @Published var dislikes: Int?
    @Published var chat: [ChatMessage] = []
    @Published var showChat = Settings.shared.liveChatEnabled
    @Published var sleepAt: Date?
    @Published var audioOnly = false

    private var cues: [Cue] = []
    private var loader: HLSResourceLoader?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObs: NSKeyValueObservation?
    private var rateObs: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var chatTask: Task<Void, Never>?
    private var skippedSegments = Set<String>()
    private var lastWatchtimeReport: Double = 0
    private var watchStart: Double = 0
    private var backStack: [MediaItem] = []
    private var shuffleBag: [MediaItem] = []

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.volume = Float(Settings.shared.volume)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        rateObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor in self?.isPlaying = p.timeControlStatus != .paused }
        }
        setupRemoteCommands()
    }

    // MARK: Loading

    func play(_ item: MediaItem, startAt: Double? = nil, pushHistory: Bool = true) {
        if let cur = self.item, pushHistory, cur.videoId != item.videoId { backStack.append(cur) }
        reportFinalWatchtime()
        loadTask?.cancel()
        chatTask?.cancel()
        self.item = item
        isVisible = true
        isMinimized = false
        error = nil
        isLoading = true
        info = nil
        details = nil
        segments = []
        skippedSegments = []
        captionText = nil
        cues = []
        chat = []
        dislikes = nil
        currentChapter = nil
        skipPrompt = nil
        player.replaceCurrentItem(with: nil)

        guard let videoId = item.videoId else {
            if let pid = item.playlistId { playPlaylist(pid) }
            return
        }

        loadTask = Task { [weak self] in
            guard let self else { return }
            async let detailsTask = try? YouTubeService.details(videoId: videoId, playlistId: item.playlistId,
                                                                playlistIndex: item.playlistIndex, params: item.params)
            async let segmentsTask = SponsorBlockService.segments(videoId)
            async let dislikeTask = DislikeService.votes(videoId)
            do {
                let info = try await PlayerService.streams(videoId: videoId, playlistId: item.playlistId)
                if Task.isCancelled { return }
                self.info = info
                self.duration = info.lengthSeconds
                try await self.startPlayback(info, startAt: startAt ?? self.resumePosition(for: item, info: info))
                Task { await PlayerService.reportPlayback(info) }
            } catch {
                if Task.isCancelled { return }
                self.error = error.localizedDescription
                self.isLoading = false
            }
            let d = await detailsTask
            if Task.isCancelled { return }
            self.details = d
            if var cur = self.item, let d {
                if cur.title.isEmpty { cur.title = d.title }
                cur.subtitle = cur.subtitle ?? d.channelName
                cur.channelId = cur.channelId ?? d.channelId
                self.item = cur
                self.applyChannelPrefs(d.channelId)
                if let chatToken = d.liveChatContinuation, Settings.shared.liveChatEnabled { self.startChat(chatToken) }
            }
            self.segments = await segmentsTask
            if let excluded = self.item?.channelId, Settings.shared.sponsorExcludedChannels.contains(excluded) { self.segments = [] }
            self.dislikes = await dislikeTask?.dislikes
            self.updateNowPlaying()
        }
    }

    private func playPlaylist(_ playlistId: String) {
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await YouTubeService.playlist(playlistId)
                if var first = page.allItems.first(where: { $0.videoId != nil }) {
                    first.playlistId = playlistId
                    first.playlistIndex = 0
                    self.play(first, pushHistory: false)
                } else {
                    self.error = "Playlist is empty"; self.isLoading = false
                }
            } catch {
                self.error = error.localizedDescription; self.isLoading = false
            }
        }
    }

    private func startPlayback(_ info: StreamInfo, startAt: Double?, selection: HLSBuilder.Selection? = nil) async throws {
        let s = Settings.shared
        let playerItem: AVPlayerItem
        if info.isLive || (info.formats.isEmpty && info.hlsURL != nil), let hls = info.hlsURL {
            // live / HLS-native streams
            playerItem = AVPlayerItem(url: hls)
            qualityOptions = [QualityOption(title: "Auto", itag: nil, maxHeight: nil)]
            if s.preferredQuality > 0 {
                playerItem.preferredMaximumResolution = CGSize(width: s.preferredQuality * 16 / 9, height: s.preferredQuality)
            }
            loader = nil
        } else {
            let preferAV1: Bool
            switch s.codec {
            case .auto: preferAV1 = PlayerService.av1Supported
            case .avc: preferAV1 = false
            case .av1: preferAV1 = true
            }
            let sel = selection ?? HLSBuilder.Selection(maxHeight: s.preferredQuality > 0 ? s.preferredQuality : nil,
                                                       exactVideoItag: nil, preferAV1: preferAV1, audioOnly: audioOnly)
            let builder = HLSBuilder(info: info, selection: sel)
            guard builder.isPlayable else {
                if let hls = info.hlsURL {
                    return try await startPlaybackHLS(hls, startAt: startAt)
                }
                throw APIError.unplayable(info.isUpcoming ? "This live stream hasn't started yet" : "No playable formats (try another codec in Settings)")
            }
            let loader = HLSResourceLoader(builder: builder)
            let asset = AVURLAsset(url: loader.masterURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.queue)
            self.loader = loader
            playerItem = AVPlayerItem(asset: asset)
            let all = HLSBuilder(info: info, selection: .init(maxHeight: nil, exactVideoItag: nil, preferAV1: preferAV1)).videoVariants
            qualityOptions = [QualityOption(title: "Auto", itag: nil, maxHeight: nil)]
                + all.map { QualityOption(title: $0.label + (($0.fps ?? 0) > 30 ? " \($0.fps!)fps" : ""), itag: $0.itag, maxHeight: $0.height) }
            if selection == nil {
                selectedQuality = qualityOptions.first
            }
            currentVideoFormat = builder.videoVariants.first?.label ?? ""
        }
        playerItem.audioTimePitchAlgorithm = s.pitchCorrection ? .timeDomain : .varispeed
        playerItem.preferredForwardBufferDuration = 30
        attach(playerItem)
        if let startAt, startAt > 1 {
            await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        }
        player.playImmediately(atRate: Float(speed))
        isLoading = false
        watchStart = startAt ?? 0
        lastWatchtimeReport = watchStart

        captionTracks = info.captions
        let wanted = s.subtitlesPerChannel ? (info.channelId.flatMap { s.channelSubtitles($0) } ?? (s.subtitlesEnabled ? s.subtitleLanguage : nil))
            : (s.subtitlesEnabled ? s.subtitleLanguage : nil)
        if let wanted {
            let track = info.captions.first { $0.languageCode == wanted && $0.kind != "asr" }
                ?? info.captions.first { $0.languageCode == wanted }
                ?? (wanted.isEmpty ? info.captions.first : nil)
            if let track { selectCaption(track) }
        }
        Task { await self.loadAudioOptions(playerItem) }
        updateNowPlaying()
    }

    private func startPlaybackHLS(_ url: URL, startAt: Double?) async throws {
        let item = AVPlayerItem(url: url)
        attach(item)
        player.playImmediately(atRate: Float(speed))
        isLoading = false
    }

    private func attach(_ playerItem: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinish() }
        }
        statusObs = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in
                guard let self else { return }
                if it.status == .failed {
                    self.handleFailure(it.error)
                } else if it.status == .readyToPlay, it.duration.isNumeric {
                    self.duration = it.duration.seconds
                }
            }
        }
        player.replaceCurrentItem(with: playerItem)
    }

    private func handleFailure(_ err: Error?) {
        // expired URLs or codec issue: retry once with AVC
        if let info, info.expires < Date(), let item {
            play(item, startAt: currentTime, pushHistory: false)
            return
        }
        error = err?.localizedDescription ?? "Playback failed"
        isLoading = false
    }

    private func loadAudioOptions(_ item: AVPlayerItem) async {
        guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else { return }
        audioOptions = group.options
        selectedAudio = item.currentMediaSelection.selectedMediaOption(in: group)
    }

    // MARK: Tick

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if let r = player.currentItem?.loadedTimeRanges.last?.timeRangeValue { bufferedTime = (r.start + r.duration).seconds }
        captionText = cues.isEmpty ? nil : Captions.text(at: t, in: cues)
        handleSegments(t)
        handleChapters(t)
        if let sleepAt, Date() >= sleepAt { player.pause(); self.sleepAt = nil; toast = "Sleep timer: paused" }
        if isPlaying, t - lastWatchtimeReport >= 10 || t < lastWatchtimeReport {
            let from = lastWatchtimeReport
            lastWatchtimeReport = t
            if let info { Task { await PlayerService.reportWatchtime(info, from: from, to: t) } }
            savePosition(t)
        }
    }

    private func handleSegments(_ t: Double) {
        let s = Settings.shared
        var prompt: SponsorSegment?
        for seg in segments where seg.category != .poi_highlight && seg.actionType != "full" {
            guard t >= seg.start && t < seg.end - 0.3 else { continue }
            let action = s.sponsorAction(seg.category)
            if action == .skip {
                if s.sponsorSkipOnce && skippedSegments.contains(seg.uuid) { continue }
                skippedSegments.insert(seg.uuid)
                seek(to: seg.end)
                flash("Skipped: \(seg.category.title)")
                return
            } else if action == .showToast {
                prompt = seg
            }
        }
        if skipPrompt?.uuid != prompt?.uuid { skipPrompt = prompt }
    }

    private func handleChapters(_ t: Double) {
        guard let chapters = details?.chapters, !chapters.isEmpty else { return }
        let ch = chapters.last { $0.start <= t }
        if ch?.start != currentChapter?.start {
            currentChapter = ch
            if let ch, Settings.shared.chapterNotifications, t > 1 { flash(ch.title) }
        }
    }

    func flash(_ text: String) {
        toast = text
        let current = text
        Task { try? await Task.sleep(nanoseconds: 2_500_000_000); if self.toast == current { self.toast = nil } }
    }

    // MARK: End of video / queue

    private func didFinish() {
        reportFinalWatchtime()
        guard let item else { return }
        clearPosition(item)
        let mode = Settings.shared.playbackMode
        let isShort = info?.isShort ?? (item.kind == .short)
        if isShort && Settings.shared.loopShorts && mode != .playAll {
            seek(to: 0); player.play(); return
        }
        switch mode {
        case .repeatOne:
            seek(to: 0); player.play()
        case .pauseAfterEach:
            break
        case .stopAfterEach, .closeAfterEach:
            close()
        case .shuffle:
            let pool = (details?.playlist?.items ?? details?.related.flatMap(\.items) ?? []).filter { $0.videoId != nil && $0.videoId != item.videoId }
            if let n = pool.randomElement() { play(n) }
        case .repeatList:
            if let q = details?.playlist, !q.items.isEmpty {
                let nextIdx = (q.currentIndex + 1) % q.items.count
                var n = q.items[nextIdx]; n.playlistId = q.playlistId; n.playlistIndex = nextIdx
                play(n)
            } else { seek(to: 0); player.play() }
        case .playAll:
            playNext()
        }
    }

    var nextItem: MediaItem? {
        if let q = details?.playlist, q.currentIndex + 1 < q.items.count {
            var n = q.items[q.currentIndex + 1]; n.playlistId = q.playlistId; n.playlistIndex = q.currentIndex + 1
            return n
        }
        if let a = details?.autoplayNext { return a }
        return details?.related.flatMap(\.items).first { $0.videoId != nil && $0.kind != .short || Settings.shared.skipShorts == false && $0.videoId != nil }
    }

    func playNext() {
        if let n = nextItem { play(n) }
    }

    func playPrevious() {
        if currentTime > 5 { seek(to: 0); return }
        if let q = details?.playlist, q.currentIndex > 0 {
            var p = q.items[q.currentIndex - 1]; p.playlistId = q.playlistId; p.playlistIndex = q.currentIndex - 1
            play(p, pushHistory: false); return
        }
        if let prev = backStack.popLast() { play(prev, pushHistory: false) }
    }

    // MARK: Controls

    func togglePlay() {
        if player.timeControlStatus == .paused {
            if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
            player.playImmediately(atRate: Float(speed))
        } else {
            player.pause()
        }
    }

    func seek(to t: Double) {
        let target = max(0, duration > 0 ? min(t, duration - 0.1) : t)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if Settings.shared.pauseOnSeek { player.pause() }
    }

    func seek(by delta: Double) { seek(to: currentTime + delta) }

    func setSpeed(_ v: Double) {
        speed = v
        Settings.shared.speed = v
        if Settings.shared.rememberSpeedPerChannel, let c = item?.channelId { Settings.shared.setChannelSpeed(c, v) }
        if Settings.shared.speedPerVideo, let id = item?.videoId { Settings.shared.setVideoSpeed(id, v) }
        if isPlaying { player.rate = Float(v) }
        if #available(macOS 13.0, *) { player.defaultRate = Float(v) }
        flash(String(format: "Speed %.2gx", v))
    }

    func setVolume(_ v: Double) {
        player.volume = Float(v)
        Settings.shared.volume = v
    }

    func selectQuality(_ q: QualityOption) {
        guard let info else { return }
        selectedQuality = q
        if q.itag == nil, q.maxHeight == nil {
            Settings.shared.preferredQuality = 0
        } else if let h = q.maxHeight {
            Settings.shared.preferredQuality = h
        }
        let t = currentTime
        let preferAV1 = q.title.contains("AV1") || (Settings.shared.codec == .auto && PlayerService.av1Supported && q.itag == nil)
        let sel = HLSBuilder.Selection(maxHeight: q.maxHeight, exactVideoItag: q.itag, preferAV1: preferAV1, audioOnly: audioOnly)
        Task { try? await startPlayback(info, startAt: t, selection: sel) }
    }

    func setAudioOnly(_ on: Bool) {
        audioOnly = on
        guard let info else { return }
        let t = currentTime
        Task { try? await startPlayback(info, startAt: t) }
    }

    func selectAudio(_ option: AVMediaSelectionOption) {
        guard let item = player.currentItem else { return }
        Task {
            if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
                item.select(option, in: group)
                selectedAudio = option
                if let lang = option.extendedLanguageTag ?? option.locale?.identifier { Settings.shared.audioLanguage = lang }
            }
        }
    }

    func selectCaption(_ track: CaptionTrack?, translate: String? = nil) {
        selectedCaption = track
        cues = []
        captionText = nil
        let s = Settings.shared
        if let translate { captionTranslation = translate; s.subtitleAutoTranslate = translate }
        guard let track else {
            s.subtitlesEnabled = false
            if s.subtitlesPerChannel, let c = info?.channelId { s.setChannelSubtitles(c, nil) }
            return
        }
        s.subtitlesEnabled = true
        s.subtitleLanguage = track.languageCode
        if s.subtitlesPerChannel, let c = info?.channelId { s.setChannelSubtitles(c, track.languageCode) }
        let tl = captionTranslation.isEmpty || captionTranslation == track.languageCode ? nil : captionTranslation
        Task {
            do { self.cues = try await Captions.load(track, translateTo: tl) }
            catch { self.flash("Subtitles failed to load") }
        }
    }

    func skipCurrentSegment() {
        if let s = skipPrompt { seek(to: s.end); skipPrompt = nil }
    }

    func jumpToHighlight() {
        if let h = segments.first(where: { $0.category == .poi_highlight }) { seek(to: h.start) }
    }

    func setSleepTimer(minutes: Int) {
        sleepAt = minutes > 0 ? Date().addingTimeInterval(TimeInterval(minutes * 60)) : nil
        flash(minutes > 0 ? "Sleep timer: \(minutes) min" : "Sleep timer off")
    }

    func close() {
        reportFinalWatchtime()
        if let t = Optional(currentTime), t > 0 { savePosition(t) }
        loadTask?.cancel()
        chatTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        isVisible = false
        item = nil
        info = nil
        details = nil
        loader = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Account actions

    func toggleLike(_ status: LikeStatus) {
        guard var d = details else { return }
        let old = d.likeStatus
        let new: LikeStatus = old == status ? .none : status
        d.likeStatus = new
        details = d
        Task {
            do { try await ActionsService.setLike(d.videoId, from: old, to: new) }
            catch { self.details?.likeStatus = old; self.flash(error.localizedDescription) }
        }
    }

    func toggleSubscribe() {
        guard var d = details, let cid = d.channelId else { return }
        let was = d.subscribed
        d.subscribed.toggle()
        details = d
        Task {
            do {
                if was { try await ActionsService.unsubscribe(cid, params: d.subscribeParams) }
                else { try await ActionsService.subscribe(cid, params: d.subscribeParams) }
                self.flash(was ? "Unsubscribed" : "Subscribed")
            } catch { self.details?.subscribed = was; self.flash(error.localizedDescription) }
        }
    }

    // MARK: Live chat

    private func startChat(_ token: String) {
        chatTask?.cancel()
        chatTask = Task { [weak self] in
            var cont: String? = token
            while let c = cont, !Task.isCancelled {
                guard let r = try? await YouTubeService.liveChat(c) else { break }
                await MainActor.run {
                    guard let self else { return }
                    self.chat.append(contentsOf: r.messages)
                    if self.chat.count > 300 { self.chat.removeFirst(self.chat.count - 300) }
                }
                cont = r.next
                try? await Task.sleep(nanoseconds: UInt64(max(r.pollMs, 1000)) * 1_000_000)
            }
        }
    }

    // MARK: Position memory

    private func positionKey(_ id: String) -> String { "pos.\(id)" }

    private func resumePosition(for item: MediaItem, info: StreamInfo) -> Double? {
        if let s = item.startSeconds { return s }
        let s = Settings.shared
        guard s.rememberPosition, let id = item.videoId else { return nil }
        if info.isLive && !s.rememberPositionLive { return nil }
        if info.isShort && !s.rememberPositionShorts { return nil }
        let saved = UserDefaults.standard.double(forKey: positionKey(id))
        if saved > 5 && saved < info.lengthSeconds - 10 { return saved }
        if let p = item.watchedPercent, p > 2, p < 95 { return info.lengthSeconds * p / 100 }
        return nil
    }

    private func savePosition(_ t: Double) {
        guard let id = item?.videoId, Settings.shared.rememberPosition, !(info?.isLive ?? false) else { return }
        UserDefaults.standard.set(t, forKey: positionKey(id))
    }

    private func clearPosition(_ item: MediaItem) {
        if let id = item.videoId { UserDefaults.standard.removeObject(forKey: positionKey(id)) }
    }

    private func reportFinalWatchtime() {
        guard let info, currentTime > lastWatchtimeReport else { return }
        let from = lastWatchtimeReport, to = currentTime
        lastWatchtimeReport = to
        Task { await PlayerService.reportWatchtime(info, from: from, to: to) }
    }

    private func applyChannelPrefs(_ channelId: String?) {
        let s = Settings.shared
        if s.speedPerVideo, let id = item?.videoId, let v = s.videoSpeed(id) { setSpeedSilently(v) }
        else if s.rememberSpeedPerChannel, let c = channelId, let v = s.channelSpeed(c) { setSpeedSilently(v) }
    }

    private func setSpeedSilently(_ v: Double) {
        speed = v
        if isPlaying { player.rate = Float(v) }
    }

    // MARK: Now Playing / media keys

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.play() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.player.pause() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playNext() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.playPrevious() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            if let e = e as? MPChangePlaybackPositionCommandEvent { Task { @MainActor in self?.seek(to: e.positionTime) } }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item?.title ?? self.info?.title ?? "",
            MPMediaItemPropertyArtist: item?.subtitle ?? self.info?.author ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? speed : 0
        ]
        if self.info?.isLive == true { info[MPNowPlayingInfoPropertyIsLiveStream] = true }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
