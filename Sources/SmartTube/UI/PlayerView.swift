import SwiftUI
import AVKit
import AppKit

/// NSView hosting an AVPlayerLayer with picture-in-picture support.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    var pip: AVPictureInPictureController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: playerLayer)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity
    var onCreate: (PlayerLayerView) -> Void = { _ in }

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        onCreate(v)
        return v
    }

    func updateNSView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }
}

enum SidePanel: String, CaseIterable, Identifiable {
    case upNext = "Up next", comments = "Comments", chapters = "Chapters", info = "Description", chat = "Live chat"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .upNext: return "list.bullet.rectangle"
        case .comments: return "text.bubble"
        case .chapters: return "list.number"
        case .info: return "info.circle"
        case .chat: return "bubble.left.and.bubble.right"
        }
    }
}

struct PlayerScreen: View {
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: AppModel
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: SidePanel?
    @State private var layerView: PlayerLayerView?
    @FocusState private var focused: Bool

    var gravity: AVLayerVideoGravity {
        switch settings.resizeMode { case 1: return .resizeAspectFill; case 2: return .resize; default: return .resizeAspect }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.black
                VideoSurface(player: player.player, gravity: gravity) { v in DispatchQueue.main.async { layerView = v } }
                    .scaleEffect(x: CGFloat(settings.zoomPercent) / 100 * (settings.videoFlip ? -1 : 1), y: CGFloat(settings.zoomPercent) / 100)
                    .rotationEffect(.degrees(Double(settings.rotation)))
                if player.audioOnly, let thumb = player.info?.thumbnail ?? player.item?.thumbnail {
                    AsyncImage(url: thumb) { $0.resizable().scaledToFit() } placeholder: { Color.black }
                }
                if let caption = player.captionText { CaptionOverlay(text: caption) }
                if player.isLoading { ProgressView().controlSize(.large).tint(.white) }
                if let err = player.error { errorView(err) }
                if showControls || !player.isPlaying {
                    ControlsOverlay(panel: $panel, pip: { layerView?.pip?.startPictureInPicture() })
                        .transition(.opacity)
                }
                VStack {
                    if let t = player.toast {
                        Text(t).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
                            .padding(.top, 70)
                    }
                    Spacer()
                    if let seg = player.skipPrompt {
                        HStack { Spacer()
                            Button { player.skipCurrentSegment() } label: {
                                Label("Skip \(seg.category.title)", systemImage: "forward.end.fill").padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent).tint(Color(hex: seg.category.colorHex))
                            .padding(.trailing, 24).padding(.bottom, 110)
                        }
                    }
                }
                if settings.showClock || settings.showQualityInfo {
                    VStack { HStack { Spacer(); infoBadge }.padding(12); Spacer() }
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { poke() }
            }
            .onTapGesture(count: 2) { toggleFullScreen() }
            .onTapGesture { player.togglePlay(); poke() }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .onAppear { focused = true; poke() }

            if let panel {
                SidePanelView(panel: Binding(get: { panel }, set: { self.panel = $0 }))
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.18), value: showControls)
        .animation(.easeInOut(duration: 0.18), value: panel)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if settings.autoPiP && player.isPlaying { layerView?.pip?.startPictureInPicture() }
        }
        .onChange(of: player.details?.isLive) { _, live in
            if live == true, settings.liveChatEnabled, panel == nil { panel = .chat }
        }
    }

    var infoBadge: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if settings.showClock { Text(Date.now, style: .time).monospacedDigit() }
            if settings.showQualityInfo { Text(player.currentVideoFormat).font(.caption) }
        }
        .padding(6).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6)).foregroundStyle(.white)
    }

    func errorView(_ err: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle)
            Text(err).multilineTextAlignment(.center).frame(maxWidth: 500)
            HStack {
                Button("Retry") { if let i = player.item { player.play(i, pushHistory: false) } }
                Button("Next video") { player.playNext() }
                Button("Close") { player.close() }
            }
        }.foregroundStyle(.white).padding()
    }

    func poke() {
        showControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(settings.uiHideTimeout * 1_000_000_000))
            if !Task.isCancelled && player.isPlaying { showControls = false }
        }
    }

    func toggleFullScreen() { NSApp.keyWindow?.toggleFullScreen(nil) }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        poke()
        let inc = settings.seekIncrement
        switch press.key {
        case .space: player.togglePlay()
        case .leftArrow: player.seek(by: press.modifiers.contains(.shift) ? -inc * 3 : -inc)
        case .rightArrow: player.seek(by: press.modifiers.contains(.shift) ? inc * 3 : inc)
        case .upArrow: player.setVolume(min(1, Double(player.player.volume) + 0.05)); player.flash("Volume \(Int(player.player.volume * 100))%")
        case .downArrow: player.setVolume(max(0, Double(player.player.volume) - 0.05)); player.flash("Volume \(Int(player.player.volume * 100))%")
        case .escape:
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true { toggleFullScreen() } else { player.isMinimized = true }
        default:
            switch press.characters {
            case "k": player.togglePlay()
            case "j": player.seek(by: -10)
            case "l": player.seek(by: 10)
            case "f": toggleFullScreen()
            case "m": player.player.isMuted.toggle(); player.flash(player.player.isMuted ? "Muted" : "Unmuted")
            case "c":
                if player.selectedCaption != nil { player.selectCaption(nil) }
                else if let t = player.captionTracks.first { player.selectCaption(t) }
            case "N": player.playNext()
            case "P": player.playPrevious()
            case ">": player.setSpeed(min(4, player.speed + 0.25))
            case "<": player.setSpeed(max(0.25, player.speed - 0.25))
            case "i": player.isMinimized = true
            case "s": player.skipCurrentSegment()
            case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let n = Double(press.characters), player.duration > 0 { player.seek(to: player.duration * n / 10) }
            default: return .ignored
            }
        }
        return .handled
    }
}

struct CaptionOverlay: View {
    let text: String
    @EnvironmentObject var settings: Settings
    var body: some View {
        GeometryReader { g in
            VStack {
                Spacer()
                let style = settings.subtitleStyle
                let yellow = style == 2 || style == 3
                let outline = style == 1 || style == 3
                Text(text)
                    .font(.system(size: max(14, g.size.height / 24) * settings.subtitleScale, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(yellow ? Color.yellow : Color.white)
                    .shadow(color: .black, radius: outline ? 2 : 0)
                    .shadow(color: .black, radius: outline ? 2 : 0)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(outline ? Color.clear : Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .padding(.bottom, g.size.height * settings.subtitlePosition)
                    .frame(maxWidth: .infinity)
            }
        }
        .allowsHitTesting(false)
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

func formatTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: Mini player

struct MiniPlayer: View {
    @EnvironmentObject var player: PlayerController
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoSurface(player: player.player, gravity: .resizeAspect)
                    .onTapGesture { player.isMinimized = false }
            }
            .frame(width: 320, height: 180)
            HStack {
                Text(player.item?.title ?? "").font(.caption).lineLimit(1)
                Spacer()
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }
                Button { player.playNext() } label: { Image(systemName: "forward.end.fill") }
                Button { player.isMinimized = false } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                Button { player.close() } label: { Image(systemName: "xmark") }
            }
            .buttonStyle(.borderless)
            .padding(8)
            .frame(width: 320)
            .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 12)
    }
}
