import SwiftUI

enum Route: Hashable {
    case channel(id: String, title: String, params: String? = nil)
    case playlist(id: String, title: String)
    case browse(id: String, params: String?, title: String)
    case search(String)
    case group(UUID)
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var section: AppSection? = AppSection(rawValue: Settings.shared.startSection) ?? .home
    @Published var path: [Route] = []
    @Published var accounts: [Account] = []
    @Published var account: Account?
    @Published var showSignIn = false
    @Published var showOpenURL = false
    @Published var searchText = ""
    @Published var searchFocusToken = UUID()
    @Published var reloadToken = UUID()
    @Published var alert: String?

    init() {
        Task { await refreshAccounts() }
    }

    func refreshAccounts() async {
        accounts = await AuthService.shared.accounts
        account = await AuthService.shared.selected
    }

    func switchAccount(_ id: String?) {
        Task {
            await AuthService.shared.select(id)
            await refreshAccounts()
            reloadToken = UUID()
        }
    }

    func signOut(_ id: String) {
        Task {
            await AuthService.shared.remove(id)
            await refreshAccounts()
            reloadToken = UUID()
        }
    }

    func push(_ r: Route) { path.append(r) }
    func goBack() { if !path.isEmpty { path.removeLast() } }

    func focusSearch() {
        searchFocusToken = UUID()
    }

    func search(_ q: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let url = URL(string: q), url.host?.contains("youtu") == true { open(url: url); return }
        path.append(.search(q))
    }

    func openChannel(_ id: String, title: String = "") {
        PlayerController.shared.isMinimized = PlayerController.shared.isVisible
        path.append(.channel(id: id, title: title))
    }

    /// Handles item activation from any grid.
    func open(_ item: MediaItem) {
        switch item.kind {
        case .channel:
            if let id = item.channelId { path.append(.channel(id: id, title: item.title, params: nil)) }
        case .playlist:
            if let id = item.playlistId { path.append(.playlist(id: id, title: item.title)) }
        default:
            PlayerController.shared.play(item)
        }
    }

    /// youtube.com / youtu.be links
    func open(url: URL) {
        let s = url.absoluteString
        if let v = url.queryValue("v") ?? (url.host == "youtu.be" ? url.pathComponents.dropFirst().first : nil)
            ?? s.firstMatch(#"/(?:shorts|live|embed)/([A-Za-z0-9_-]{11})"#) {
            var m = MediaItem.video(v)
            m.playlistId = url.queryValue("list")
            if let t = url.queryValue("t").flatMap({ Double($0.replacingOccurrences(of: "s", with: "")) }) { m.startSeconds = t }
            PlayerController.shared.play(m)
        } else if let list = url.queryValue("list") {
            path.append(.playlist(id: list, title: "Playlist"))
        } else if let ch = s.firstMatch(#"/channel/(UC[A-Za-z0-9_-]+)"#) {
            path.append(.channel(id: ch, title: ""))
        } else if let handle = s.firstMatch(#"/(@[^/?#]+)"#) {
            Task {
                if let j = try? await InnerTube.post("navigation/resolve_url", ["url": "https://www.youtube.com/\(handle)"], client: .web, auth: false),
                   let id = j.first("browseEndpoint")["browseId"].string {
                    self.path.append(.channel(id: id, title: handle))
                } else {
                    self.alert = "Could not open \(handle)"
                }
            }
        } else {
            alert = "Unsupported link"
        }
    }
}
