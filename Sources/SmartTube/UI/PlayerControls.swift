import SwiftUI
import AVKit

struct ControlsOverlay: View {
    @Binding var panel: SidePanel?
    var pip: () -> Void
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 30)
                .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            Spacer()
            VStack(spacing: 8) {
                SeekBar()
                bottomBar
            }
            .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 40)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
        .buttonStyle(.borderless)
    }

    var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { player.isMinimized = true } label: { Image(systemName: "chevron.down").font(.title2) }
                .help("Minimize (i)")
            VStack(alignment: .leading, spacing: 3) {
                Text(player.details?.title ?? player.item?.title ?? player.info?.title ?? "")
                    .font(.title3.bold()).lineLimit(2)
                HStack(spacing: 8) {
                    if let cid = player.details?.channelId ?? player.info?.channelId {
                        Button(player.details?.channelName ?? player.info?.author ?? "") {
                            player.isMinimized = true
                            model.openChannel(cid, title: player.details?.channelName ?? "")
                        }.font(.callout)
                    }
                    if let v = player.details?.viewCount { Text(v).font(.caption).opacity(0.8) }
                    if let d = player.details?.date { Text(d).font(.caption).opacity(0.8) }
                    if let ch = player.currentChapter { Text("• \(ch.title)").font(.caption).opacity(0.9) }
                }
            }
            Spacer()
            if player.details != nil { accountButtons }
            Button { player.close() } label: { Image(systemName: "xmark").font(.title2) }.help("Close")
        }
    }

    var accountButtons: some View {
        HStack(spacing: 14) {
            Button { player.toggleLike(.like) } label: {
                Label(settings.showLikesCounter ? (player.details?.likeCount ?? "") : "", systemImage: player.details?.likeStatus == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
            }.help("Like")
            Button { player.toggleLike(.dislike) } label: {
                Label(settings.showLikesCounter ? (player.dislikes.map(compact) ?? "") : "", systemImage: player.details?.likeStatus == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
            }.help("Dislike")
            if player.details?.channelId != nil {
                Button(player.details?.subscribed == true ? "Subscribed" : "Subscribe") { player.toggleSubscribe() }
                    .buttonStyle(.borderedProminent).tint(player.details?.subscribed == true ? .gray : .red)
            }
            if let vid = player.item?.videoId {
                Menu { PlaylistPickerMenu(videoId: vid) } label: { Image(systemName: "text.badge.plus") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Save to playlist")
            }
        }
    }

    var bottomBar: some View {
        HStack(spacing: 16) {
            Button { player.playPrevious() } label: { Image(systemName: "backward.end.fill") }.help("Previous (P)")
            Button { player.seek(by: -settings.seekIncrement) } label: { Image(systemName: "gobackward.10") }
            Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title) }
                .help("Play/Pause (space)")
            Button { player.seek(by: settings.seekIncrement) } label: { Image(systemName: "goforward.10") }
            Button { player.playNext() } label: { Image(systemName: "forward.end.fill") }.help("Next (N)")
            VolumeControl()
            timeLabel
            Spacer()
            if player.segments.contains(where: { $0.category == .poi_highlight }) {
                Button { player.jumpToHighlight() } label: { Image(systemName: "star.fill") }.help("Jump to highlight")
            }
            speedMenu
            captionsMenu
            if player.audioOptions.count > 1 { audioMenu }
            qualityMenu
            moreMenu
            ForEach(SidePanel.allCases.filter { $0 != .chat || player.details?.liveChatContinuation != nil }
                .filter { $0 != .chapters || !(player.details?.chapters.isEmpty ?? true) }) { p in
                Button { panel = panel == p ? nil : p } label: { Image(systemName: p.icon) }
                    .help(p.rawValue)
                    .foregroundStyle(panel == p ? Color.accentColor : .white)
            }
            Button(action: pip) { Image(systemName: "pip.enter") }.help("Picture in picture")
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Full screen (f)")
        }
        .font(.title3)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    var timeLabel: some View {
        HStack(spacing: 4) {
            if player.info?.isLive == true {
                Text("● LIVE").foregroundStyle(.red).font(.caption.bold())
                if player.duration.isFinite, player.duration - player.currentTime > 30 {
                    Button("Go live") { player.seek(to: player.duration) }.font(.caption)
                }
            } else {
                Text("\(formatTime(player.currentTime)) / \(formatTime(player.duration))")
                if settings.showRemainingTime, player.duration > 0 {
                    Text("(-\(formatTime((player.duration - player.currentTime) / max(player.speed, 0.1))))").opacity(0.7)
                }
                if settings.showEndingTime, player.duration > 0 {
                    Text("ends \(Date().addingTimeInterval((player.duration - player.currentTime) / max(player.speed, 0.1)), style: .time)").opacity(0.7)
                }
            }
        }
        .font(.callout.monospacedDigit())
    }

    var speeds: [Double] {
        settings.allowAllSpeeds ? stride(from: 0.25, through: 4.0, by: 0.05).map { ($0 * 100).rounded() / 100 }
            : [0.25, 0.5, 0.75, 0.8, 0.9, 1.0, 1.1, 1.15, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5, 2.75, 3.0, 3.5, 4.0]
    }

    var speedMenu: some View {
        Menu {
            ForEach(speeds, id: \.self) { s in
                Button { player.setSpeed(s) } label: {
                    if abs(player.speed - s) < 0.001 { Label(String(format: "%.2gx", s), systemImage: "checkmark") } else { Text(String(format: "%.2gx", s)) }
                }
            }
            Divider()
            Toggle("Remember per channel", isOn: Binding(get: { settings.rememberSpeedPerChannel }, set: { settings.rememberSpeedPerChannel = $0 }))
            Toggle("Remember per video", isOn: Binding(get: { settings.speedPerVideo }, set: { settings.speedPerVideo = $0 }))
        } label: { Text(String(format: "%.2gx", player.speed)).font(.callout.bold()) }
        .fixedSize().help("Speed")
    }

    var captionsMenu: some View {
        Menu {
            Button { player.selectCaption(nil) } label: {
                if player.selectedCaption == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
            }
            ForEach(player.captionTracks) { t in
                Button { player.selectCaption(t) } label: {
                    let name = t.kind == "asr" ? "\(t.name)" : t.name
                    if player.selectedCaption?.id == t.id { Label(name, systemImage: "checkmark") } else { Text(name) }
                }
            }
            if let tr = player.info?.translationLanguages, !tr.isEmpty, player.selectedCaption?.isTranslatable == true {
                Divider()
                Menu("Auto-translate") {
                    Button("Original") { player.selectCaption(player.selectedCaption, translate: "") }
                    ForEach(tr, id: \.code) { l in
                        Button { player.selectCaption(player.selectedCaption, translate: l.code) } label: {
                            if player.captionTranslation == l.code { Label(l.name, systemImage: "checkmark") } else { Text(l.name) }
                        }
                    }
                }
            }
            Divider()
            Menu("Style") {
                Picker("Style", selection: Binding(get: { settings.subtitleStyle }, set: { settings.subtitleStyle = $0 })) {
                    Text("White on black").tag(0); Text("White outline").tag(1); Text("Yellow on black").tag(2); Text("Yellow outline").tag(3)
                }.pickerStyle(.inline)
                Picker("Size", selection: Binding(get: { settings.subtitleScale }, set: { settings.subtitleScale = $0 })) {
                    ForEach([0.6, 0.8, 1.0, 1.2, 1.4, 1.7, 2.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }.pickerStyle(.inline)
                Picker("Position", selection: Binding(get: { settings.subtitlePosition }, set: { settings.subtitlePosition = $0 })) {
                    ForEach([0.02, 0.08, 0.15, 0.25, 0.4], id: \.self) { Text("\(Int($0 * 100))% from bottom").tag($0) }
                }.pickerStyle(.inline)
            }
        } label: { Image(systemName: player.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill") }
        .fixedSize().help("Subtitles (c)").disabled(player.captionTracks.isEmpty)
    }

    var audioMenu: some View {
        Menu {
            ForEach(player.audioOptions, id: \.self) { o in
                Button { player.selectAudio(o) } label: {
                    if o == player.selectedAudio { Label(o.displayName, systemImage: "checkmark") } else { Text(o.displayName) }
                }
            }
        } label: { Image(systemName: "waveform") }.fixedSize().help("Audio track")
    }

    var qualityMenu: some View {
        Menu {
            ForEach(player.qualityOptions) { q in
                Button { player.selectQuality(q) } label: {
                    if player.selectedQuality?.id == q.id { Label(q.title, systemImage: "checkmark") } else { Text(q.title) }
                }
            }
            Divider()
            Toggle("Audio only", isOn: Binding(get: { player.audioOnly }, set: { player.setAudioOnly($0) }))
        } label: { Image(systemName: "gearshape") }.fixedSize().help("Quality")
    }

    var moreMenu: some View {
        Menu {
            Picker("Playback mode", selection: Binding(get: { settings.playbackMode }, set: { settings.playbackMode = $0 })) {
                ForEach(PlaybackMode.allCases) { Text($0.title).tag($0) }
            }
            Menu("Sleep timer") {
                ForEach([0, 15, 30, 45, 60, 90, 120], id: \.self) { m in
                    Button(m == 0 ? "Off" : "\(m) minutes") { player.setSleepTimer(minutes: m) }
                }
            }
            Menu("Video") {
                Picker("Resize", selection: Binding(get: { settings.resizeMode }, set: { settings.resizeMode = $0 })) {
                    Text("Fit").tag(0); Text("Fill / crop").tag(1); Text("Stretch").tag(2)
                }
                Picker("Zoom", selection: Binding(get: { settings.zoomPercent }, set: { settings.zoomPercent = $0 })) {
                    ForEach([100, 110, 125, 150, 175, 200], id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker("Rotate", selection: Binding(get: { settings.rotation }, set: { settings.rotation = $0 })) {
                    ForEach([0, 90, 180, 270], id: \.self) { Text("\($0)°").tag($0) }
                }
                Toggle("Mirror", isOn: Binding(get: { settings.videoFlip }, set: { settings.videoFlip = $0 }))
            }
            Toggle("Show clock", isOn: Binding(get: { settings.showClock }, set: { settings.showClock = $0 }))
            Toggle("Show quality info", isOn: Binding(get: { settings.showQualityInfo }, set: { settings.showQualityInfo = $0 }))
            Divider()
            if let cid = player.details?.channelId {
                Button("Exclude channel from SponsorBlock") {
                    var e = settings.sponsorExcludedChannels; if !e.contains(cid) { e.append(cid) }; settings.sponsorExcludedChannels = e
                    player.segments = []
                }
            }
            if let id = player.item?.videoId {
                Button("Copy link") { copy("https://youtu.be/\(id)") }
                Button("Copy link at current time") { copy("https://youtu.be/\(id)?t=\(Int(player.currentTime))") }
                Button("Open in browser") { NSWorkspace.shared.open(URL(string: "https://www.youtube.com/watch?v=\(id)")!) }
            }
        } label: { Image(systemName: "ellipsis.circle") }.fixedSize().help("More")
    }

    func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        player.flash("Link copied")
    }
}

func compact(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: return String(format: "%.1fB", Double(n) / 1e9)
    case 1_000_000...: return String(format: "%.1fM", Double(n) / 1e6)
    case 1_000...: return String(format: "%.0fK", Double(n) / 1e3)
    default: return "\(n)"
    }
}

struct VolumeControl: View {
    @EnvironmentObject var player: PlayerController
    @State private var volume: Double = Settings.shared.volume
    var body: some View {
        HStack(spacing: 6) {
            Button { player.player.isMuted.toggle(); volume = player.player.isMuted ? 0 : Double(player.player.volume) } label: {
                Image(systemName: volume == 0 ? "speaker.slash.fill" : volume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill")
            }
            Slider(value: $volume, in: 0...1).frame(width: 80)
                .onChange(of: volume) { _, v in player.player.isMuted = false; player.setVolume(v) }
        }
    }
}

struct SeekBar: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: Settings
    @State private var hoverX: CGFloat?
    @State private var dragValue: Double?

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let dur = max(player.duration, 0.001)
            let cur = dragValue ?? player.currentTime
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25)).frame(height: 5)
                Capsule().fill(.white.opacity(0.4)).frame(width: w * min(1, player.bufferedTime / dur), height: 5)
                if settings.sponsorShowOnSeekbar {
                    ForEach(player.segments) { s in
                        Rectangle().fill(Color(hex: s.category.colorHex))
                            .frame(width: max(2, w * (s.end - s.start) / dur), height: 5)
                            .offset(x: w * s.start / dur)
                    }
                }
                Capsule().fill(Color.red).frame(width: w * min(1, cur / dur), height: 5)
                ForEach(player.details?.chapters ?? []) { ch in
                    if ch.start > 0 {
                        Rectangle().fill(.black).frame(width: 2, height: 5).offset(x: w * ch.start / dur)
                    }
                }
                Circle().fill(Color.red).frame(width: 13, height: 13).offset(x: w * min(1, cur / dur) - 6.5)
                if let x = hoverX {
                    preview(at: Double(x / w) * dur)
                        .offset(x: min(max(0, x - 80), w - 160), y: -70)
                }
            }
            .frame(height: 20)
            .contentShape(Rectangle())
            .onContinuousHover { p in
                if case .active(let pt) = p { hoverX = pt.x } else { hoverX = nil }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in dragValue = Double(max(0, min(v.location.x, w)) / w) * dur; hoverX = v.location.x }
                .onEnded { v in
                    player.seek(to: Double(max(0, min(v.location.x, w)) / w) * dur)
                    dragValue = nil
                })
        }
        .frame(height: 20)
        .disabled(player.info?.isLive == true && player.duration <= 0)
    }

    @ViewBuilder func preview(at t: Double) -> some View {
        VStack(spacing: 2) {
            if let sb = player.info?.storyboard, let f = sb.frame(at: t, duration: player.duration) {
                StoryboardFrame(url: f.url, x: f.x, y: f.y, w: sb.width, h: sb.height, cols: sb.columns, rows: sb.rows)
                    .frame(width: 160, height: 160 * CGFloat(sb.height) / CGFloat(max(sb.width, 1)))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            let chapter = player.details?.chapters.last { $0.start <= t }
            Text((chapter.map { $0.title + " · " } ?? "") + formatTime(t))
                .font(.caption.monospacedDigit()).lineLimit(1)
                .padding(.horizontal, 4).background(.black.opacity(0.7))
        }
        .frame(width: 160)
        .allowsHitTesting(false)
    }
}

/// Crops one tile out of a storyboard sprite sheet.
struct StoryboardFrame: View {
    let url: URL
    let x: Int, y: Int, w: Int, h: Int, cols: Int, rows: Int
    var body: some View {
        GeometryReader { g in
            let scale = g.size.width / CGFloat(max(w, 1))
            AsyncImage(url: url, transaction: Transaction(animation: nil)) { phase in
                if case .success(let img) = phase {
                    img.resizable()
                        .interpolation(.medium)
                        .frame(width: CGFloat(w * cols) * scale, height: CGFloat(h * rows) * scale, alignment: .topLeading)
                        .offset(x: -CGFloat(x) * scale, y: -CGFloat(y) * scale)
                } else { Color.black }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .clipped()
        }
    }
}
