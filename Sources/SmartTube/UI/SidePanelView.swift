import SwiftUI

struct SidePanelView: View {
    @Binding var panel: SidePanel?
    @EnvironmentObject var player: PlayerController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: Binding(get: { panel ?? .upNext }, set: { panel = $0 })) {
                    ForEach(SidePanel.allCases.filter { $0 != .chat || player.details?.liveChatContinuation != nil }) {
                        Image(systemName: $0.icon).help($0.rawValue).tag($0)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                Button { panel = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }.padding(10)
            Text(panel?.rawValue ?? "").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            Divider().padding(.top, 6)
            switch panel ?? .upNext {
            case .upNext: UpNextPanel()
            case .comments: CommentsPanel(token: player.details?.commentsToken)
            case .chapters: ChaptersPanel()
            case .info: DescriptionPanel()
            case .chat: ChatPanel()
            }
        }
        .background(.regularMaterial)
        .environment(\.colorScheme, .dark)
    }
}

struct UpNextPanel: View {
    @EnvironmentObject var player: PlayerController
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let q = player.details?.playlist {
                    Text("\(q.title) · \(q.currentIndex + 1)/\(q.items.count)").font(.subheadline.bold()).padding(.horizontal, 12)
                    ForEach(Array(q.items.enumerated()), id: \.offset) { i, item in
                        row(item, current: i == q.currentIndex) {
                            var m = item; m.playlistId = q.playlistId; m.playlistIndex = i; player.play(m)
                        }
                    }
                    Divider()
                }
                if let next = player.nextItem, player.details?.playlist == nil {
                    Text("Autoplay next").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                    row(next, current: false) { player.play(next) }
                    Divider()
                }
                ForEach(player.details?.related ?? []) { shelf in
                    if !shelf.title.isEmpty { Text(shelf.title).font(.subheadline.bold()).padding(.horizontal, 12) }
                    ForEach(shelf.items) { item in
                        row(item, current: false) { AppModel.shared.open(item); if item.kind == .channel || item.kind == .playlist { player.isMinimized = true } }
                    }
                }
            }.padding(.vertical, 10)
        }
    }

    func row(_ item: MediaItem, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                AsyncImage(url: item.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary) }
                    .frame(width: 136, height: 76).clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomTrailing) {
                        if let d = item.duration { Text(d).font(.caption2.bold()).padding(2).background(.black.opacity(0.7)).padding(3) }
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(current ? .bold : .regular)).lineLimit(2)
                    if let s = item.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    if let i = item.info { Text(i).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 2)
            .background(current ? Color.accentColor.opacity(0.2) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { ItemMenu(item: item) }
    }
}

struct CommentsPanel: View {
    let token: String?
    @State private var page: CommentsPage?
    @State private var comments: [Comment] = []
    @State private var loading = false
    @State private var error: String?
    @State private var repliesFor: Comment?

    var body: some View {
        Group {
            if let parent = repliesFor, let t = parent.repliesToken {
                VStack(alignment: .leading, spacing: 0) {
                    Button { repliesFor = nil } label: { Label("Back to comments", systemImage: "chevron.left") }
                        .buttonStyle(.borderless).padding(10)
                    CommentRow(comment: parent).padding(.horizontal, 12)
                    Divider()
                    CommentsPanel(token: t)
                }
            } else if token == nil {
                Text("Comments are turned off").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let opts = page?.sortOptions, opts.count > 1 {
                            HStack {
                                ForEach(opts, id: \.token) { o in
                                    Button(o.title) { Task { await load(o.token, reset: true) } }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        }
                        ForEach(comments) { c in
                            CommentRow(comment: c) { repliesFor = c }
                                .onAppear { if c.id == comments.last?.id { Task { await more() } } }
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity) }
                        if let error { Text(error).foregroundStyle(.secondary) }
                    }.padding(12)
                }
            }
        }
        .task(id: token) { if let token { await load(token, reset: true) } }
    }

    func load(_ t: String, reset: Bool) async {
        loading = true; defer { loading = false }
        do {
            let p = try await YouTubeService.comments(t)
            if reset { comments = p.comments } else { comments += p.comments }
            if reset && !(page?.sortOptions.isEmpty ?? true) && p.sortOptions.isEmpty {
                page = CommentsPage(title: p.title, comments: [], continuation: p.continuation, sortOptions: page!.sortOptions)
            } else { page = p }
        } catch { self.error = error.localizedDescription }
    }

    func more() async {
        guard !loading, let c = page?.continuation else { return }
        await load(c, reset: false)
    }
}

struct CommentRow: View {
    let comment: Comment
    var showReplies: (() -> Void)? = nil
    @State private var liked: Bool?
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AsyncImage(url: comment.authorThumbnail) { $0.resizable() } placeholder: { Circle().fill(.quaternary) }
                .frame(width: 30, height: 30).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if comment.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                    Text(comment.author).font(.caption.bold())
                    if let p = comment.published { Text(p).font(.caption).foregroundStyle(.secondary) }
                }
                Text(comment.text).font(.callout).textSelection(.enabled)
                HStack(spacing: 12) {
                    Button {
                        let now = !(liked ?? comment.isLiked)
                        liked = now
                        if let a = now ? comment.likeAction : comment.unlikeAction { Task { try? await ActionsService.commentAction(a) } }
                    } label: {
                        Label(comment.likes ?? "", systemImage: (liked ?? comment.isLiked) ? "hand.thumbsup.fill" : "hand.thumbsup")
                    }.buttonStyle(.borderless).font(.caption)
                    if comment.isHearted { Image(systemName: "heart.fill").foregroundStyle(.red).font(.caption) }
                    if comment.repliesToken != nil, let showReplies {
                        Button(comment.repliesCount.map { "\($0) replies" } ?? "Replies", action: showReplies)
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
            }
        }
    }
}

struct ChaptersPanel: View {
    @EnvironmentObject var player: PlayerController
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(player.details?.chapters ?? []) { ch in
                    Button { player.seek(to: ch.start) } label: {
                        HStack {
                            AsyncImage(url: ch.thumbnail) { $0.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary) }
                                .frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading) {
                                Text(ch.title).font(.callout).lineLimit(2)
                                Text(formatTime(ch.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(4)
                        .background(player.currentChapter?.start == ch.start ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }.padding(10)
        }
    }
}

struct DescriptionPanel: View {
    @EnvironmentObject var player: PlayerController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(player.details?.title ?? "").font(.headline)
                HStack {
                    if let v = player.details?.viewCount { Text(v) }
                    if let d = player.details?.date { Text(d) }
                }.font(.caption).foregroundStyle(.secondary)
                if let d = player.details {
                    HStack {
                        AsyncImage(url: d.channelAvatar) { $0.resizable() } placeholder: { Circle().fill(.quaternary) }
                            .frame(width: 36, height: 36).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(d.channelName ?? "").font(.callout.bold())
                            if let s = d.subscriberCount { Text(s).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                Text(linkified(player.details?.description ?? "")).font(.callout).textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        if url.host?.contains("youtu") == true { AppModel.shared.open(url: url); return .handled }
                        if url.scheme == "seek", let t = Double(url.host ?? "") { PlayerController.shared.seek(to: t); return .handled }
                        return .systemAction
                    })
            }.padding(12)
        }
    }

    /// Makes URLs and timestamps (1:23) clickable.
    func linkified(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for m in det.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range, in: s), let ar = Range(r, in: a), let u = m.url else { continue }
                a[ar].link = u
            }
        }
        if let re = try? NSRegularExpression(pattern: #"\b(\d{1,2}:)?\d{1,2}:\d{2}\b"#) {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                guard let r = Range(m.range, in: s), let ar = Range(r, in: a), let secs = Parser.parseDuration(String(s[r])) else { continue }
                a[ar].link = URL(string: "seek://\(secs)")
            }
        }
        return a
    }
}

struct ChatPanel: View {
    @EnvironmentObject var player: PlayerController
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(player.chat) { m in
                        HStack(alignment: .top, spacing: 6) {
                            AsyncImage(url: m.authorPhoto) { $0.resizable() } placeholder: { Circle().fill(.quaternary) }
                                .frame(width: 20, height: 20).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.author).font(.caption.bold())
                                    .foregroundStyle(m.isOwner ? .yellow : m.isModerator ? .blue : m.isMember ? .green : .secondary)
                                if let sc = m.superChat { Text(sc).font(.caption.bold()).padding(.horizontal, 4).background(.orange, in: Capsule()) }
                                Text(m.message).font(.callout)
                            }
                        }.id(m.id)
                    }
                }.padding(10)
            }
            .onChange(of: player.chat.count) { _, _ in
                if let last = player.chat.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
