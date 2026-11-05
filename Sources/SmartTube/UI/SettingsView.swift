import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var s: Settings
    @State private var unlocked = false
    @State private var attempt = ""

    var body: some View {
        if !s.settingsPassword.isEmpty && !unlocked {
            VStack(spacing: 12) {
                Image(systemName: "lock").font(.largeTitle)
                SecureField("Settings password", text: $attempt).frame(width: 240)
                    .onSubmit { unlocked = attempt == s.settingsPassword; attempt = "" }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            tabs
        }
    }

    var tabs: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            PlayerSettings().tabItem { Label("Player", systemImage: "play.rectangle") }
            SubtitleSettings().tabItem { Label("Subtitles", systemImage: "captions.bubble") }
            SponsorBlockSettings().tabItem { Label("SponsorBlock", systemImage: "forward.end") }
            ContentSettings().tabItem { Label("Content", systemImage: "rectangle.grid.2x2") }
            AccountSettings().tabItem { Label("Account", systemImage: "person.crop.circle") }
            BackupSettings().tabItem { Label("Backup", systemImage: "externaldrive") }
        }
        .padding()
    }
}

private func bind<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> { Binding(get: get, set: set) }

struct GeneralSettings: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Section("Sidebar sections") {
                ForEach(AppSection.defaultOrder) { sec in
                    Toggle(sec.title, isOn: bind({ s.enabledSections.contains(sec.rawValue) }, { on in
                        var list = s.enabledSections.filter { $0 != sec.rawValue }
                        if on { list = AppSection.defaultOrder.map(\.rawValue).filter { list.contains($0) || $0 == sec.rawValue } }
                        s.enabledSections = list
                    }))
                }
                Toggle("Trending", isOn: bind({ s.enabledSections.contains(AppSection.trending.rawValue) }, { on in
                    var l = s.enabledSections.filter { $0 != AppSection.trending.rawValue }; if on { l.append(AppSection.trending.rawValue) }; s.enabledSections = l
                }))
                Toggle("Kids", isOn: bind({ s.enabledSections.contains(AppSection.kids.rawValue) }, { on in
                    var l = s.enabledSections.filter { $0 != AppSection.kids.rawValue }; if on { l.append(AppSection.kids.rawValue) }; s.enabledSections = l
                }))
                Picker("Start section", selection: bind({ s.startSection }, { s.startSection = $0 })) {
                    ForEach(AppSection.defaultOrder) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("Language & region") {
                TextField("Content language (hl), e.g. en, de, es", text: bind({ s.language }, { s.language = $0 }))
                TextField("Country (gl), e.g. US, GB, DE", text: bind({ s.country }, { s.country = $0.uppercased() }))
                Toggle("Restricted mode (safe search)", isOn: bind({ s.safeSearch }, { s.safeSearch = $0 }))
            }
            Section("Appearance") {
                Picker("Theme", selection: bind({ s.colorScheme }, { s.colorScheme = $0 })) {
                    Text("System").tag(0); Text("Dark").tag(1); Text("Light").tag(2)
                }
                Picker("Accent color", selection: bind({ s.accentColor }, { s.accentColor = $0 })) {
                    ForEach(AccentColors.names.indices, id: \.self) { Text(AccentColors.names[$0]).tag($0) }
                }
                Slider(value: bind({ s.gridScale }, { s.gridScale = $0 }), in: 0.7...1.6, step: 0.1) { Text("Card size") }
                Toggle("Two-line titles", isOn: bind({ s.multilineTitles }, { s.multilineTitles = $0 }))
            }
            Section("Privacy") {
                SecureField("Settings password (empty = none)", text: bind({ s.settingsPassword }, { s.settingsPassword = $0 }))
            }
        }.formStyle(.grouped)
    }
}

struct PlayerSettings: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Section("Video") {
                Picker("Default quality", selection: bind({ s.preferredQuality }, { s.preferredQuality = $0 })) {
                    Text("Auto").tag(0)
                    ForEach([4320, 2160, 1440, 1080, 720, 480, 360, 240, 144], id: \.self) { Text("\($0)p").tag($0) }
                }
                Picker("Codec", selection: bind({ s.codec }, { s.codec = $0 })) {
                    ForEach(VideoCodecPreference.allCases) { Text($0.title).tag($0) }
                }
                Text(PlayerService.av1Supported ? "This Mac decodes AV1 in hardware: up to 8K available." : "No AV1 hardware decoder: quality is limited to what H.264 offers (usually 1080p).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Prefer 60fps", isOn: bind({ s.preferHighFPS }, { s.preferHighFPS = $0 }))
            }
            Section("Playback") {
                Picker("After a video ends", selection: bind({ s.playbackMode }, { s.playbackMode = $0 })) {
                    ForEach(PlaybackMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Default speed", selection: bind({ s.speed }, { s.speed = $0 })) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0], id: \.self) { Text(String(format: "%.2gx", $0)).tag($0) }
                }
                Toggle("Remember speed per channel", isOn: bind({ s.rememberSpeedPerChannel }, { s.rememberSpeedPerChannel = $0 }))
                Toggle("Remember speed per video", isOn: bind({ s.speedPerVideo }, { s.speedPerVideo = $0 }))
                Toggle("Show all speeds (0.05 steps)", isOn: bind({ s.allowAllSpeeds }, { s.allowAllSpeeds = $0 }))
                Toggle("Keep pitch when changing speed", isOn: bind({ s.pitchCorrection }, { s.pitchCorrection = $0 }))
                Picker("Seek step", selection: bind({ s.seekIncrement }, { s.seekIncrement = $0 })) {
                    ForEach([5.0, 10, 15, 20, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Toggle("Pause after seeking", isOn: bind({ s.pauseOnSeek }, { s.pauseOnSeek = $0 }))
                Toggle("Remember position", isOn: bind({ s.rememberPosition }, { s.rememberPosition = $0 }))
                Toggle("Remember position of live streams", isOn: bind({ s.rememberPositionLive }, { s.rememberPositionLive = $0 }))
                Toggle("Remember position of Shorts", isOn: bind({ s.rememberPositionShorts }, { s.rememberPositionShorts = $0 }))
                Toggle("Loop Shorts", isOn: bind({ s.loopShorts }, { s.loopShorts = $0 }))
                Toggle("Skip Shorts in autoplay", isOn: bind({ s.skipShorts }, { s.skipShorts = $0 }))
                TextField("Preferred audio language (e.g. en, de; empty = original)", text: bind({ s.audioLanguage }, { s.audioLanguage = $0 }))
            }
            Section("Interface") {
                Picker("Hide controls after", selection: bind({ s.uiHideTimeout }, { s.uiHideTimeout = $0 })) {
                    ForEach([2.0, 3, 5, 8, 15], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Toggle("Show remaining time", isOn: bind({ s.showRemainingTime }, { s.showRemainingTime = $0 }))
                Toggle("Show ending time", isOn: bind({ s.showEndingTime }, { s.showEndingTime = $0 }))
                Toggle("Show clock", isOn: bind({ s.showClock }, { s.showClock = $0 }))
                Toggle("Show quality info", isOn: bind({ s.showQualityInfo }, { s.showQualityInfo = $0 }))
                Toggle("Show like / dislike counters", isOn: bind({ s.showLikesCounter }, { s.showLikesCounter = $0 }))
                Toggle("Chapter notifications", isOn: bind({ s.chapterNotifications }, { s.chapterNotifications = $0 }))
                Toggle("Open live chat automatically", isOn: bind({ s.liveChatEnabled }, { s.liveChatEnabled = $0 }))
                Toggle("Keep playing when window closes (background playback)", isOn: bind({ s.backgroundPlayback }, { s.backgroundPlayback = $0 }))
                Toggle("Picture-in-picture when switching apps", isOn: bind({ s.autoPiP }, { s.autoPiP = $0 }))
            }
        }.formStyle(.grouped)
    }
}

struct SubtitleSettings: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Toggle("Enable subtitles by default", isOn: bind({ s.subtitlesEnabled }, { s.subtitlesEnabled = $0 }))
            TextField("Preferred language code (e.g. en)", text: bind({ s.subtitleLanguage }, { s.subtitleLanguage = $0 }))
            TextField("Auto-translate to (empty = off)", text: bind({ s.subtitleAutoTranslate }, { s.subtitleAutoTranslate = $0 }))
            Toggle("Remember subtitles per channel", isOn: bind({ s.subtitlesPerChannel }, { s.subtitlesPerChannel = $0 }))
            Picker("Style", selection: bind({ s.subtitleStyle }, { s.subtitleStyle = $0 })) {
                Text("White on black").tag(0); Text("White outline").tag(1); Text("Yellow on black").tag(2); Text("Yellow outline").tag(3)
            }
            Slider(value: bind({ s.subtitleScale }, { s.subtitleScale = $0 }), in: 0.5...2.5, step: 0.1) { Text("Size") }
            Slider(value: bind({ s.subtitlePosition }, { s.subtitlePosition = $0 }), in: 0...0.5, step: 0.01) { Text("Position") }
        }.formStyle(.grouped)
    }
}

struct SponsorBlockSettings: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Toggle("Enable SponsorBlock", isOn: bind({ s.sponsorBlockEnabled }, { s.sponsorBlockEnabled = $0 }))
            Section("Categories") {
                ForEach(SponsorCategory.allCases) { c in
                    Picker(selection: bind({ s.sponsorAction(c) }, { s.setSponsorAction(c, $0) })) {
                        ForEach(SegmentAction.allCases) { Text($0.title).tag($0) }
                    } label: {
                        HStack { Circle().fill(Color(hex: c.colorHex)).frame(width: 10, height: 10); Text(c.title) }
                    }
                }
            }
            Section("Options") {
                Toggle("Show segments on seek bar", isOn: bind({ s.sponsorShowOnSeekbar }, { s.sponsorShowOnSeekbar = $0 }))
                Toggle("Don't skip the same segment twice", isOn: bind({ s.sponsorSkipOnce }, { s.sponsorSkipOnce = $0 }))
                Toggle("Notify about paid promotion", isOn: bind({ s.sponsorPaidNotification }, { s.sponsorPaidNotification = $0 }))
                Picker("Ignore segments shorter than", selection: bind({ s.sponsorMinDuration }, { s.sponsorMinDuration = $0 })) {
                    ForEach([0.0, 1, 2, 3, 5, 10], id: \.self) { Text($0 == 0 ? "Off" : "\(Int($0)) s").tag($0) }
                }
            }
            if !s.sponsorExcludedChannels.isEmpty {
                Section("Excluded channels") {
                    ForEach(s.sponsorExcludedChannels, id: \.self) { c in
                        HStack { Text(c); Spacer(); Button("Remove") { s.sponsorExcludedChannels.removeAll { $0 == c } } }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct ContentSettings: View {
    @EnvironmentObject var s: Settings
    var body: some View {
        Form {
            Section("Shorts") {
                Toggle("Hide Shorts on Home", isOn: bind({ s.hideShortsHome }, { s.hideShortsHome = $0 }))
                Toggle("Hide Shorts in Subscriptions", isOn: bind({ s.hideShortsSubscriptions }, { s.hideShortsSubscriptions = $0 }))
                Toggle("Hide Shorts in History", isOn: bind({ s.hideShortsHistory }, { s.hideShortsHistory = $0 }))
                Toggle("Hide Shorts on channels", isOn: bind({ s.hideShortsChannel }, { s.hideShortsChannel = $0 }))
                Toggle("Hide Shorts in search", isOn: bind({ s.hideShortsSearch }, { s.hideShortsSearch = $0 }))
            }
            Section("Filters") {
                Toggle("Hide upcoming videos", isOn: bind({ s.hideUpcoming }, { s.hideUpcoming = $0 }))
                Toggle("Hide watched videos", isOn: bind({ s.hideWatched }, { s.hideWatched = $0 }))
                Picker("Watched means at least", selection: bind({ s.hideWatchedPercent }, { s.hideWatchedPercent = $0 })) {
                    ForEach([25, 50, 75, 90, 100], id: \.self) { Text("\($0)%").tag($0) }
                }
            }
            Section("Community services") {
                Toggle("Return YouTube Dislike counts", isOn: bind({ s.returnDislikes }, { s.returnDislikes = $0 }))
                Toggle("DeArrow: crowd-sourced titles", isOn: bind({ s.deArrowTitles }, { s.deArrowTitles = $0 }))
                Toggle("DeArrow: crowd-sourced thumbnails", isOn: bind({ s.deArrowThumbnails }, { s.deArrowThumbnails = $0 }))
            }
            if !s.blockedChannels.isEmpty {
                Section("Blocked channels") {
                    ForEach(s.blockedChannels.sorted(by: { $0.value < $1.value }), id: \.key) { pair in
                        HStack { Text(pair.value); Spacer(); Button("Unblock") { var b = s.blockedChannels; b[pair.key] = nil; s.blockedChannels = b } }
                    }
                }
            }
        }.formStyle(.grouped)
    }
}

struct AccountSettings: View {
    @EnvironmentObject var s: Settings
    @EnvironmentObject var model: AppModel
    @State private var status: String?
    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(model.accounts) { a in
                    HStack {
                        Text(a.name); if let e = a.email { Text(e).foregroundStyle(.secondary) }
                        Spacer()
                        if a.id == model.account?.id { Text("Active").foregroundStyle(.secondary) } else { Button("Switch") { model.switchAccount(a.id) } }
                        Button("Sign out", role: .destructive) { model.signOut(a.id) }
                    }
                }
                Button("Add account…") { model.showSignIn = true }
            }
            Section("History") {
                Toggle("Save watch history (sends watch time to YouTube)", isOn: bind({ s.historyEnabled }, { s.historyEnabled = $0 }))
                HStack {
                    Button("Pause YouTube watch history") { act { try await ActionsService.pauseWatchHistory() } }
                    Button("Resume") { act { try await ActionsService.resumeWatchHistory() } }
                    Button("Clear watch history", role: .destructive) { act { try await ActionsService.clearWatchHistory() } }
                }
                Toggle("Save search history", isOn: bind({ s.searchHistoryEnabled }, { s.searchHistoryEnabled = $0 }))
                Button("Clear search history") { act { try await ActionsService.clearSearchHistory() } }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }

    func act(_ op: @escaping () async throws -> Void) {
        Task { do { try await op(); status = "Done" } catch { status = error.localizedDescription } }
    }
}

struct BackupSettings: View {
    @EnvironmentObject var s: Settings
    @State private var exporting = false
    @State private var importing = false
    @State private var status: String?
    var body: some View {
        Form {
            Section("Backup") {
                Button("Export settings…") { exporting = true }
                Button("Import settings…") { importing = true }
                if let status { Text(status).font(.caption) }
            }
            Section("Maintenance") {
                Button("Clear cache (player scripts, thumbnails)") { DiskCache.clear(); URLCache.shared.removeAllCachedResponses(); Task { await AppInfo.shared.invalidate() }; status = "Cache cleared" }
                Button("Reset all settings", role: .destructive) { s.reset(); status = "Settings reset" }
            }
            Section("About") {
                Text("SmartTube for macOS — a native port of SmartTube (github.com/yuliskov/SmartTube). MIT licensed.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .fileExporter(isPresented: $exporting, document: BackupDocument(data: s.exportBackup()), contentType: .propertyList, defaultFilename: "SmartTube-backup") { r in
            if case .success = r { status = "Exported" }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .xml, .data]) { r in
            guard case .success(let url) = r else { return }
            let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do { try s.importBackup(try Data(contentsOf: url)); status = "Imported" } catch { status = error.localizedDescription }
        }
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
