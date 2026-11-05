import SwiftUI
import AppKit

struct ItemCard: View {
    let item: MediaItem
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: Settings
    @State private var hover = false
    @State private var deArrowTitle: String?
    @State private var deArrowThumb: URL?

    var aspect: CGFloat { item.kind == .short ? 9.0 / 16.0 : 16.0 / 9.0 }

    var body: some View {
        Button { model.open(item) } label: {
            VStack(alignment: .leading, spacing: 6) {
                thumbnail
                HStack(alignment: .top, spacing: 8) {
                    if item.kind != .channel, let ch = item.channelThumbnail, item.kind != .short {
                        AsyncImage(url: ch) { $0.resizable() } placeholder: { Circle().fill(.quaternary) }
                            .frame(width: 28, height: 28).clipShape(Circle())
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deArrowTitle ?? (item.title.isEmpty ? " " : item.title))
                            .font(.callout.weight(.semibold))
                            .lineLimit(settings.multilineTitles ? 2 : 1)
                            .multilineTextAlignment(.leading)
                        if let s = item.subtitle, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if let i = item.info, !i.isEmpty { Text(i).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .contextMenu { ItemMenu(item: item) }
        .task(id: item.videoId) {
            guard let id = item.videoId, settings.deArrowTitles || settings.deArrowThumbnails else { return }
            let b = await DeArrowService.shared.branding(id)
            deArrowTitle = b.title; deArrowThumb = b.thumb
        }
    }

    var thumbnail: some View {
        Color.clear
            .aspectRatio(item.kind == .channel ? 16.0 / 9.0 : aspect, contentMode: .fit)
            .overlay {
                AsyncImage(url: deArrowThumb ?? item.thumbnail) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: Rectangle().fill(.quaternary)
                    }
                }
                .if(item.kind == .channel) { $0.clipShape(Circle()).padding(12) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) { badge.padding(6) }
            .overlay(alignment: .bottom) {
                if let p = item.watchedPercent, p > 0 {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.4))
                            Rectangle().fill(Color.red).frame(width: g.size.width * min(p, 100) / 100)
                        }
                    }.frame(height: 4).clipShape(RoundedRectangle(cornerRadius: 2))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: hover ? 3 : 0)
            }
            .scaleEffect(hover ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: hover)
    }

    @ViewBuilder var badge: some View {
        if item.kind == .live {
            Text("LIVE").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.red, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        } else if item.kind == .upcoming {
            Text("UPCOMING").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        } else if let d = item.duration {
            Text(d).font(.caption2.monospacedDigit().bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        } else if item.kind == .playlist || item.kind == .mix {
            Label(item.info ?? "Playlist", systemImage: "list.bullet").font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 2).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white)
        }
    }
}

extension View {
    @ViewBuilder func `if`<T: View>(_ cond: Bool, transform: (Self) -> T) -> some View {
        if cond { transform(self) } else { self }
    }
}

/// Context menu for any card (SmartTube's long-press menu).
struct ItemMenu: View {
    let item: MediaItem
    @EnvironmentObject var model: AppModel
    @State private var showPlaylists = false

    var body: some View {
        if item.videoId != nil {
            Button("Play") { PlayerController.shared.play(item) }
            Button("Play audio only") {
                PlayerController.shared.audioOnly = true
                PlayerController.shared.play(item)
            }
            Button("Add to Watch later") { run("Added to Watch later") { try await ActionsService.addToPlaylist("WL", videoId: item.videoId!) } }
            Menu("Add to playlist") { PlaylistPickerMenu(videoId: item.videoId!) }
        }
        if let cid = item.channelId, item.kind != .channel {
            Button("Open channel") { model.push(.channel(id: cid, title: item.subtitle ?? "")) }
        }
        if item.kind == .channel, let cid = item.channelId {
            Button("Subscribe") { run("Subscribed") { try await ActionsService.subscribe(cid) } }
            Button("Unsubscribe") { run("Unsubscribed") { try await ActionsService.unsubscribe(cid) } }
            Menu("Add to channel group") { GroupPickerMenu(channel: GroupChannel(channelId: cid, title: item.title, thumbnail: item.thumbnail)) }
        }
        if let pid = item.playlistId, item.kind == .playlist {
            Button("Play all") { var m = item; m.videoId = nil; PlayerController.shared.play(m) }
            Button("Save playlist") { run("Playlist saved") { try await ActionsService.savePlaylist(pid) } }
            Button("Remove saved playlist") { run("Playlist removed") { try await ActionsService.unsavePlaylist(pid) } }
        }
        if !item.feedbackTokens.isEmpty {
            Divider()
            ForEach(item.feedbackTokens.keys.sorted().filter { !$0.hasPrefix("feedback") }, id: \.self) { k in
                Button(k) { run("Thanks for the feedback") { try await ActionsService.feedback(item.feedbackTokens[k]!) } }
            }
            if item.feedbackTokens.keys.allSatisfy({ $0.hasPrefix("feedback") }), let t = item.feedbackTokens.values.first {
                Button("Not interested") { run("Thanks for the feedback") { try await ActionsService.feedback(t) } }
            }
        }
        if let cid = item.channelId {
            Button("Block channel") {
                var b = Settings.shared.blockedChannels
                b[cid] = item.subtitle ?? item.title
                Settings.shared.blockedChannels = b
                model.alert = "Channel blocked. Manage in Settings → Content."
            }
        }
        Divider()
        if let url = shareURL {
            Button("Copy link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Open in browser") { NSWorkspace.shared.open(url) }
        }
    }

    var shareURL: URL? {
        if let v = item.videoId { return URL(string: item.kind == .short ? "https://youtube.com/shorts/\(v)" : "https://youtu.be/\(v)") }
        if let p = item.playlistId { return URL(string: "https://www.youtube.com/playlist?list=\(p)") }
        if let c = item.channelId { return URL(string: "https://www.youtube.com/channel/\(c)") }
        return nil
    }

    func run(_ done: String, _ op: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await op(); PlayerController.shared.flash(done); if !PlayerController.shared.isVisible { model.alert = done } }
            catch { model.alert = error.localizedDescription }
        }
    }
}

struct PlaylistPickerMenu: View {
    let videoId: String
    @State private var lists: [PlaylistInfo]?
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let lists {
                ForEach(lists) { p in
                    Button { toggle(p) } label: {
                        if p.containsVideo { Label(p.title, systemImage: "checkmark") } else { Text(p.title) }
                    }
                }
                Divider()
            } else {
                Text("Loading playlists…")
            }
            Button("New playlist…") { promptNew() }
        }
        .task { lists = (try? await ActionsService.playlistsContaining(videoId)) ?? [] }
    }

    func toggle(_ p: PlaylistInfo) {
        Task { @MainActor in
            do {
                if p.containsVideo { try await ActionsService.removeFromPlaylist(p.id, videoId: videoId) }
                else { try await ActionsService.addToPlaylist(p.id, videoId: videoId) }
                PlayerController.shared.flash(p.containsVideo ? "Removed from \(p.title)" : "Added to \(p.title)")
            } catch { model.alert = error.localizedDescription }
        }
    }

    func promptNew() {
        let alert = NSAlert()
        alert.messageText = "New playlist"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
            let title = field.stringValue
            Task { @MainActor in
                do { try await ActionsService.createPlaylist(title, videoId: videoId); PlayerController.shared.flash("Created \(title)") }
                catch { model.alert = error.localizedDescription }
            }
        }
    }
}

struct GroupPickerMenu: View {
    let channel: GroupChannel
    @ObservedObject var store = ChannelGroupStore.shared
    var body: some View {
        ForEach(store.groups) { g in Button(g.title) { store.add(channel, to: g.id) } }
        Button("New group…") {
            let alert = NSAlert()
            alert.messageText = "New channel group"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Create"); alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
                store.groups.append(ChannelGroup(title: field.stringValue, channels: [channel]))
            }
        }
    }
}
