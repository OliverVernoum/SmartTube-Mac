import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: Channel

struct ChannelView: View {
    let channelId: String
    var title: String
    var params: String?
    @EnvironmentObject var model: AppModel
    @State private var tab: YouTubeService.ChannelSection? = nil
    @State private var header: ChannelHeader?
    @State private var subscribed: Bool?
    @State private var searchText = ""
    @State private var query: String?

    var source: BrowseSource {
        if let tab { return .channel(channelId, tab, nil) }
        return .channel(channelId, nil, params)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            HStack {
                Picker("", selection: $tab) {
                    Text("Home").tag(YouTubeService.ChannelSection?.none)
                    ForEach([YouTubeService.ChannelSection.videos, .shorts, .live, .playlists, .releases, .community], id: \.self) { s in
                        Text(s.title).tag(Optional(s))
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 560)
                .onChange(of: tab) { _, _ in query = nil }
                Spacer()
                TextField("Search channel", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 200)
                    .onSubmit { query = searchText.isEmpty ? nil : searchText }
            }
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            if let q = query {
                ChannelSearchView(channelId: channelId, query: q)
            } else {
                BrowseView(source: source, title: header?.title ?? title,
                           layout: tab == nil ? .auto : .grid)
                    .id(source.key)
            }
        }
        .navigationTitle(header?.title ?? title)
        .task(id: channelId) {
            if let p = try? await YouTubeService.channel(channelId) {
                header = p.header
                subscribed = p.header?.subscribed
            }
        }
    }

    var headerView: some View {
        HStack(spacing: 14) {
            AsyncImage(url: header?.avatar) { $0.resizable() } placeholder: { Circle().fill(.quaternary) }
                .frame(width: 64, height: 64).clipShape(Circle())
            VStack(alignment: .leading) {
                Text(header?.title ?? title).font(.title2.bold())
                if let s = header?.subtitle { Text(s).foregroundStyle(.secondary) }
            }
            Spacer()
            Menu {
                GroupPickerMenu(channel: GroupChannel(channelId: channelId, title: header?.title ?? title, thumbnail: header?.avatar))
            } label: { Label("Group", systemImage: "person.3") }.fixedSize()
            Menu {
                ForEach(ActionsService.Bell.allCases, id: \.self) { b in
                    Button(b.title) { Task { try? await ActionsService.setNotifications(channelId, bell: b) } }
                }
            } label: { Image(systemName: "bell") }.fixedSize()
            Button(subscribed == true ? "Subscribed" : "Subscribe") {
                let was = subscribed == true
                subscribed = !was
                Task {
                    do {
                        if was { try await ActionsService.unsubscribe(channelId, params: header?.subscribeParams) }
                        else { try await ActionsService.subscribe(channelId, params: header?.subscribeParams) }
                    } catch { subscribed = was; model.alert = error.localizedDescription }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(subscribed == true ? .gray : .red)
        }
        .padding()
        .background {
            AsyncImage(url: header?.banner) { $0.resizable().scaledToFill().opacity(0.25) } placeholder: { Color.clear }
                .clipped()
        }
    }
}

struct ChannelSearchView: View {
    let channelId: String
    let query: String
    @State private var items: [MediaItem]?
    var body: some View {
        ScrollView {
            if let items { ItemGrid(items: items).padding(.vertical) } else { ProgressView().padding(40) }
        }
        .task(id: query) {
            items = (try? await YouTubeService.channel(channelId, section: .search, query: query).allItems) ?? []
        }
    }
}

// MARK: Playlist

struct PlaylistView: View {
    let playlistId: String
    let title: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        BrowseView(source: .playlist(playlistId), title: title, layout: .grid, header: AnyView(
            HStack {
                Button { var m = MediaItem(); m.kind = .playlist; m.playlistId = playlistId; PlayerController.shared.play(m) } label: {
                    Label("Play all", systemImage: "play.fill")
                }.buttonStyle(.borderedProminent)
                Button {
                    Task {
                        if let items = try? await YouTubeService.playlist(playlistId).allItems, var first = items.filter({ $0.videoId != nil }).randomElement() {
                            first.playlistId = playlistId
                            Settings.shared.playbackMode = .shuffle
                            PlayerController.shared.play(first)
                        }
                    }
                } label: { Label("Shuffle", systemImage: "shuffle") }
                Menu {
                    Button("Save to library") { Task { try? await ActionsService.savePlaylist(playlistId) } }
                    Button("Remove from library") { Task { try? await ActionsService.unsavePlaylist(playlistId) } }
                    Button("Rename…") { rename() }
                    Button("Delete playlist", role: .destructive) { Task { try? await ActionsService.deletePlaylist(playlistId); model.goBack() } }
                } label: { Image(systemName: "ellipsis.circle") }.fixedSize()
                Spacer()
            }.padding(.horizontal)
        ))
    }

    func rename() {
        let a = NSAlert(); a.messageText = "Rename playlist"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = title
        a.accessoryView = f; a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { Task { try? await ActionsService.renamePlaylist(playlistId, name: f.stringValue) } }
    }
}

// MARK: Search

struct SearchResultsView: View {
    let query: String
    @State private var filters = SearchFilters()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Sort", selection: $filters.sort) {
                    Text("Relevance").tag(SearchFilters.Sort.relevance)
                    Text("Upload date").tag(SearchFilters.Sort.date)
                    Text("View count").tag(SearchFilters.Sort.views)
                    Text("Rating").tag(SearchFilters.Sort.rating)
                }.fixedSize()
                Picker("Date", selection: $filters.uploadDate) {
                    Text("Any time").tag(SearchFilters.UploadDate.any)
                    Text("Last hour").tag(SearchFilters.UploadDate.hour)
                    Text("Today").tag(SearchFilters.UploadDate.today)
                    Text("This week").tag(SearchFilters.UploadDate.week)
                    Text("This month").tag(SearchFilters.UploadDate.month)
                    Text("This year").tag(SearchFilters.UploadDate.year)
                }.fixedSize()
                Picker("Type", selection: $filters.kind) {
                    Text("All").tag(SearchFilters.Kind.any)
                    Text("Videos").tag(SearchFilters.Kind.video)
                    Text("Channels").tag(SearchFilters.Kind.channel)
                    Text("Playlists").tag(SearchFilters.Kind.playlist)
                    Text("Movies").tag(SearchFilters.Kind.movie)
                }.fixedSize()
                Picker("Duration", selection: $filters.duration) {
                    Text("Any").tag(SearchFilters.Duration.any)
                    Text("Under 4 min").tag(SearchFilters.Duration.short)
                    Text("4–20 min").tag(SearchFilters.Duration.medium)
                    Text("Over 20 min").tag(SearchFilters.Duration.long)
                }.fixedSize()
                Toggle("Live", isOn: $filters.live)
                Toggle("4K", isOn: $filters.fourK)
                Toggle("HD", isOn: $filters.hd)
                Toggle("CC", isOn: $filters.subtitles)
                Spacer()
            }
            .controlSize(.small)
            .padding(.horizontal).padding(.vertical, 8)
            Divider()
            BrowseView(source: .search(query, filters), title: "“\(query)”", layout: .grid)
        }
    }
}

// MARK: Channel groups

struct ChannelGroupsView: View {
    @ObservedObject var store = ChannelGroupStore.shared
    @EnvironmentObject var model: AppModel
    @State private var importing = false

    var body: some View {
        List {
            ForEach(store.groups) { g in
                HStack {
                    Image(systemName: "person.3")
                    VStack(alignment: .leading) {
                        Text(g.title).font(.headline)
                        Text("\(g.channels.count) channels").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { model.push(.group(g.id)) }
                }
                .contextMenu {
                    Button("Rename…") {
                        let a = NSAlert(); a.messageText = "Rename group"
                        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = g.title
                        a.accessoryView = f; a.addButton(withTitle: "Rename"); a.addButton(withTitle: "Cancel")
                        if a.runModal() == .alertFirstButtonReturn, let i = store.groups.firstIndex(of: g) { store.groups[i].title = f.stringValue }
                    }
                    Button("Delete", role: .destructive) { store.groups.removeAll { $0.id == g.id } }
                }
            }
        }
        .overlay {
            if store.groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.3.sequence").font(.largeTitle)
                    Text("No channel groups yet").font(.title3)
                    Text("Right-click a channel → Add to channel group, or import from NewPipe, PocketTube or Grayjay.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                }
            }
        }
        .toolbar {
            Button { importing = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
            guard case .success(let url) = result else { return }
            let ok = url.startAccessingSecurityScopedResource()
            defer { if ok { url.stopAccessingSecurityScopedResource() } }
            do {
                let n = try store.importFile(try Data(contentsOf: url))
                model.alert = "Imported \(n) channels"
            } catch { model.alert = error.localizedDescription }
        }
        .navigationTitle("Channel groups")
    }
}

struct ChannelGroupFeedView: View {
    let groupId: UUID
    @ObservedObject var store = ChannelGroupStore.shared
    @State private var items: [MediaItem]?
    @EnvironmentObject var model: AppModel

    var group: ChannelGroup? { store.groups.first { $0.id == groupId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let g = group {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(g.channels, id: \.channelId) { c in
                                Button(c.title) { model.push(.channel(id: c.channelId, title: c.title)) }
                                    .buttonStyle(.bordered)
                                    .contextMenu { Button("Remove from group") { store.remove(c.channelId, from: g.id) } }
                            }
                        }.padding(.horizontal)
                    }
                }
                if let items { ItemGrid(items: items) } else { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }.padding(.vertical)
        }
        .navigationTitle(group?.title ?? "Group")
        .task(id: groupId) { if let g = group { items = await ChannelGroupStore.feed(g) } }
    }
}

// MARK: Sign in

struct SignInView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var code: DeviceCode?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 18) {
            Text("Sign in to YouTube").font(.title.bold())
            if let code {
                Text("On your phone or computer, go to").foregroundStyle(.secondary)
                Link(code.verificationURL, destination: URL(string: code.verificationURL) ?? URL(string: "https://yt.be/activate")!)
                    .font(.title2)
                Text("and enter this code").foregroundStyle(.secondary)
                Text(code.userCode)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary))
                HStack {
                    Button("Copy code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                    }
                    Button("Open activation page") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code.userCode, forType: .string)
                        if let u = URL(string: code.verificationURL) { NSWorkspace.shared.open(u) }
                    }
                }
                ProgressView().controlSize(.small)
                Text("Waiting for you to approve…").font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                Button("Try again") { start() }
            } else {
                ProgressView()
            }
            Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(30)
        .frame(width: 460)
        .onAppear { start() }
        .onDisappear { task?.cancel() }
    }

    func start() {
        error = nil
        code = nil
        task?.cancel()
        task = Task {
            do {
                let c = try await AuthService.shared.requestDeviceCode()
                code = c
                _ = try await AuthService.shared.waitForSignIn(c)
                await model.refreshAccounts()
                model.reloadToken = UUID()
                dismiss()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
