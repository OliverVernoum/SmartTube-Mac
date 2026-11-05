import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var player: PlayerController
    @EnvironmentObject var settings: Settings
    @StateObject private var groups = ChannelGroupStore.shared
    @State private var openURLText = ""

    var sections: [AppSection] {
        settings.enabledSections.compactMap(AppSection.init(rawValue:))
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
            } detail: {
                NavigationStack(path: $model.path) {
                    sectionView
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .channel(let id, let title, let params): ChannelView(channelId: id, title: title, params: params)
                            case .playlist(let id, let title): PlaylistView(playlistId: id, title: title)
                            case .browse(let id, let params, let title): BrowseView(source: .browse(id, params), title: title)
                            case .search(let q): SearchResultsView(query: q)
                            case .group(let id): ChannelGroupFeedView(groupId: id)
                            }
                        }
                }
                .toolbar { ToolbarItem(placement: .principal) { SearchBar() } }
            }
            .id(model.reloadToken)

            if player.isVisible && !player.isMinimized {
                PlayerScreen()
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if player.isVisible && player.isMinimized {
                MiniPlayer().padding(16).zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: player.isVisible)
        .animation(.easeInOut(duration: 0.2), value: player.isMinimized)
        .sheet(isPresented: $model.showSignIn) { SignInView() }
        .alert("Open YouTube link", isPresented: $model.showOpenURL) {
            TextField("https://youtube.com/watch?v=…", text: $openURLText)
            Button("Open") { if let u = URL(string: openURLText) { model.open(url: u) }; openURLText = "" }
            Button("Cancel", role: .cancel) {}
        }
        .alert(model.alert ?? "", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .onOpenURL { model.open(url: $0) }
    }

    @ViewBuilder var sectionView: some View {
        switch model.section ?? .home {
        case .channelGroups: ChannelGroupsView()
        case .settings: SettingsView()
        case .channels: BrowseView(source: .section(.channels), title: "Channels", layout: .channels)
        case let s: BrowseView(source: .section(s), title: s.title)
        }
    }

    var sidebar: some View {
        List(selection: Binding(get: { model.section }, set: { model.section = $0; model.path = [] })) {
            Section {
                ForEach(sections) { s in
                    Label(s.title, systemImage: s.icon).tag(s as AppSection?)
                }
                Label("Channel groups", systemImage: AppSection.channelGroups.icon).tag(AppSection.channelGroups as AppSection?)
            }
            if !groups.groups.isEmpty {
                Section("Groups") {
                    ForEach(groups.groups) { g in
                        Button { model.path = [.group(g.id)] } label: { Label(g.title, systemImage: "person.3") }
                            .buttonStyle(.plain)
                    }
                }
            }
            Section {
                Label("Settings", systemImage: "gear").tag(AppSection.settings as AppSection?)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountButton().padding(10) }
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
    }
}

struct SearchBar: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var showSuggestions = false
    @FocusState private var focused: Bool
    @State private var task: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search YouTube or paste a link", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { submit(text) }
                .onChange(of: text) { _, v in
                    task?.cancel()
                    task = Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if Task.isCancelled { return }
                        suggestions = await YouTubeService.suggestions(v)
                        showSuggestions = focused && !suggestions.isEmpty
                    }
                }
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
        .popover(isPresented: $showSuggestions, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions.prefix(12), id: \.self) { s in
                    Button { text = s; submit(s) } label: {
                        HStack {
                            Image(systemName: Settings.shared.searchHistory.contains(s) ? "clock" : "magnifyingglass").foregroundStyle(.secondary)
                            Text(s)
                            Spacer()
                        }.contentShape(Rectangle()).padding(.horizontal, 12).padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }.frame(width: 420).padding(.vertical, 6)
        }
        .onChange(of: model.searchFocusToken) { _, _ in focused = true }
    }

    func submit(_ q: String) {
        showSuggestions = false
        model.search(q)
    }
}

struct AccountButton: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            if model.accounts.isEmpty {
                Button("Sign in…") { model.showSignIn = true }
            } else {
                ForEach(model.accounts) { a in
                    Button { model.switchAccount(a.id) } label: {
                        if a.id == model.account?.id { Label(a.name, systemImage: "checkmark") } else { Text(a.name) }
                    }
                }
                Button("Use without account") { model.switchAccount(nil) }
                Divider()
                Button("Add account…") { model.showSignIn = true }
                Menu("Brand accounts") { BrandAccountsMenu() }
                if let a = model.account { Button("Sign out \(a.name)", role: .destructive) { model.signOut(a.id) } }
            }
        } label: {
            HStack {
                AsyncImage(url: model.account?.photo) { $0.resizable() } placeholder: { Image(systemName: "person.crop.circle").resizable() }
                    .frame(width: 26, height: 26).clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.account?.name ?? "Not signed in").font(.callout).lineLimit(1)
                    if let e = model.account?.email ?? model.account?.handle { Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
            }
        }
        .menuStyle(.borderlessButton)
    }
}

struct BrandAccountsMenu: View {
    @EnvironmentObject var model: AppModel
    @State private var brands: [Account] = []
    var body: some View {
        Group {
            if brands.isEmpty { Text("Loading…") }
            ForEach(brands) { b in
                Button(b.name) {
                    Task { await AuthService.shared.addOrSelect(b); await model.refreshAccounts(); model.reloadToken = UUID() }
                }
            }
        }
        .task { brands = (try? await AuthService.shared.brandAccounts()) ?? [] }
    }
}
