import SwiftUI

enum BrowseSource: Hashable {
    case section(AppSection)
    case browse(String, String?)
    case search(String, SearchFilters)
    case channel(String, YouTubeService.ChannelSection?, String?)
    case playlist(String)

    static func == (a: BrowseSource, b: BrowseSource) -> Bool { a.key == b.key }
    func hash(into h: inout Hasher) { h.combine(key) }
    var key: String {
        switch self {
        case .section(let s): return "s:\(s.rawValue)"
        case .browse(let id, let p): return "b:\(id):\(p ?? "")"
        case .search(let q, let f): return "q:\(q):\(f.params ?? "")"
        case .channel(let id, let s, let p): return "c:\(id):\(s?.rawValue ?? ""):\(p ?? "")"
        case .playlist(let id): return "p:\(id)"
        }
    }

    func load() async throws -> BrowsePage {
        switch self {
        case .section(let s): return try await YouTubeService.section(s)
        case .browse(let id, let p): return try await YouTubeService.browse(id, params: p)
        case .search(let q, let f): return try await YouTubeService.search(q, filters: f)
        case .channel(let id, let s, let p): return try await YouTubeService.channel(id, section: s, params: p)
        case .playlist(let id): return try await YouTubeService.playlist(id)
        }
    }

    var continuationEndpoint: String {
        if case .search = self { return "search" }
        return "browse"
    }
}

enum BrowseLayout { case auto, grid, channels }

/// Loads a page and shows it as rows (shelves) or as a grid, with infinite scroll.
struct BrowseView: View {
    let source: BrowseSource
    var title: String = ""
    var layout: BrowseLayout = .auto
    var header: AnyView? = nil

    @EnvironmentObject var model: AppModel
    @State private var page: BrowsePage?
    @State private var error: Error?
    @State private var loadingMore = false

    var body: some View {
        Group {
            if let page {
                content(page)
            } else if let error {
                ErrorView(error: error) { Task { await load() } }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .task(id: source) { await load() }
    }

    @ViewBuilder func content(_ page: BrowsePage) -> some View {
        let named = page.shelves.filter { !$0.title.isEmpty }
        let isGrid = layout == .grid || layout == .channels || named.count <= 1
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                if let header { header }
                if page.allItems.isEmpty {
                    Text("Nothing here yet").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                } else if isGrid {
                    let items = page.allItems
                    if let t = named.first?.title, layout != .channels { Text(t).font(.title3.bold()).padding(.horizontal) }
                    if layout == .channels {
                        ChannelGrid(items: items)
                    } else {
                        ItemGrid(items: items) { item in
                            if item.id == items.last?.id { Task { await loadMore() } }
                        }
                    }
                } else {
                    ForEach(page.shelves) { shelf in
                        ShelfRow(shelf: shelf)
                    }
                    Color.clear.frame(height: 1).onAppear { Task { await loadMore() } }
                }
                if loadingMore { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.vertical)
        }
        .refreshable { await load() }
    }

    func load() async {
        error = nil
        do { page = try await source.load() }
        catch { self.error = error; page = nil }
    }

    func loadMore() async {
        guard !loadingMore, let token = page?.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let more = try? await YouTubeService.more(token, endpoint: source.continuationEndpoint) else { return }
        guard var p = page, p.continuation == token else { return }
        let known = Set(p.allItems.map(\.id))
        let named = more.shelves.filter { !$0.title.isEmpty }
        if p.shelves.filter({ !$0.title.isEmpty }).count > 1 && !named.isEmpty {
            p.shelves += more.shelves
        } else {
            let newItems = more.allItems.filter { !known.contains($0.id) }
            if p.shelves.isEmpty { p.shelves = [Shelf(title: "", items: [])] }
            p.shelves[p.shelves.count - 1].items += newItems
        }
        p.continuation = more.continuation
        page = p
    }
}

struct ShelfRow: View {
    let shelf: Shelf
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(shelf.title).font(.title3.bold())
                Spacer()
                if let bid = shelf.browseId {
                    Button("View all") {
                        if bid.hasPrefix("UC") { model.push(.channel(id: bid, title: shelf.title, params: shelf.browseParams)) }
                        else { model.push(.browse(id: bid, params: shelf.browseParams, title: shelf.title)) }
                    }.buttonStyle(.link)
                }
            }.padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.items) { item in
                        ItemCard(item: item)
                            .frame(width: item.kind == .short ? 150 * settings.gridScale : 260 * settings.gridScale)
                    }
                }.padding(.horizontal)
            }
        }
    }
}

struct ItemGrid: View {
    let items: [MediaItem]
    var onAppear: (MediaItem) -> Void = { _ in }
    @EnvironmentObject var settings: Settings

    var body: some View {
        let allShorts = !items.isEmpty && items.allSatisfy { $0.kind == .short }
        let min = (allShorts ? 150.0 : 240.0) * settings.gridScale
        LazyVGrid(columns: [GridItem(.adaptive(minimum: min, maximum: min * 1.6), spacing: 16, alignment: .top)], spacing: 22) {
            ForEach(items) { item in
                ItemCard(item: item).onAppear { onAppear(item) }
            }
        }.padding(.horizontal)
    }
}

struct ChannelGrid: View {
    let items: [MediaItem]
    @EnvironmentObject var model: AppModel
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 20) {
            ForEach(items) { item in
                Button { model.open(item) } label: {
                    VStack {
                        AsyncImage(url: item.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Circle().fill(.quaternary) }
                            .frame(width: 96, height: 96).clipShape(Circle())
                            .overlay(alignment: .topTrailing) {
                                if item.badges.contains("NEW") { Circle().fill(.red).frame(width: 14, height: 14) }
                            }
                        Text(item.title).font(.callout).lineLimit(2).multilineTextAlignment(.center)
                    }
                }.buttonStyle(.plain)
                .contextMenu { ItemMenu(item: item) }
            }
        }.padding(.horizontal)
    }
}

struct ErrorView: View {
    let error: Error
    var retry: () -> Void
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 12) {
            if case APIError.notSignedIn = error {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 44))
                Text("Sign in to see this section").font(.title3)
                Button("Sign in") { model.showSignIn = true }.buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 40))
                Text(error.localizedDescription).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 480)
                Button("Retry", action: retry)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
