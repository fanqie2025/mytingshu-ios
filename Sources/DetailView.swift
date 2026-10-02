import SwiftUI

// MARK: - 书籍详情 + 章节（设计 §6.4，截图 03）
//
// 结构：头部（封面 100 + 标题 + 演播/作者/来源 + 更新至）→ 三列统计 → 大字简介 →
//       底部**常驻可拖拽**章节抽屉
//
// 三列统计**只用真数据**（设计 §12 偏差 2）：章节数 / 上次听到 / 来源。
// 唔语那三列是「评分 / 播放 / 收藏」，来自它的服务端，我们没有，不造假。
//
// 抽屉为什么手写而不用 `.sheet`：唔语这页的抽屉是**常驻**的，而 `.sheet` 会被用户下滑关掉；
// 想在 sheet 上做背景交互要 iOS 16.4 的 `presentationBackgroundInteraction`，高于我们的 16.0 下限。

struct DetailView: View {
    let book: Book

    @ObservedObject private var player = PlayerEngine.shared
    @ObservedObject private var library = LibraryStore.shared

    @Environment(\.dismiss) private var dismiss

    @State private var detail = BookDetail()
    @State private var loading = true
    @State private var errorText: String?
    @State private var introExpanded = false
    @State private var drawerFraction: CGFloat = 0.46
    @State private var drawerCollapsed = false
    /// 目录懒加载：下一页的页码（nil = 已到底）
    @State private var nextPage: Int?
    @State private var loadingMore = false
    @State private var loadMoreFailed = false
    @GestureState private var dragDelta: CGFloat = 0

    private var source: (any BookSource)? { SourceRegistry.source(withId: book.sourceId) }

    private var isCurrentBook: Bool { player.book?.bookURL == book.bookURL }

    private var listenedIndex: Int? {
        library.history.first(where: { $0.book.bookURL == book.bookURL })?.episodeIndex
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        stats
                        intro
                        if loading {
                            StateView(kind: .loading, title: "加载章节…", message: nil, actionTitle: nil, action: nil)
                        } else if let errorText {
                            StateView(
                                kind: .error,
                                title: "章节加载失败",
                                message: errorText,
                                actionTitle: "重试",
                                action: { Task { await load() } }
                            )
                        }
                        // 给常驻抽屉留出空间，内容不会被压在下面
                        Color.clear.frame(height: geo.size.height * drawerFraction + 12)
                    }
                    .padding(.horizontal, Theme.Space.page)
                    .padding(.top, 10)
                }
                .background(Theme.bg)

                drawer(viewport: geo.size.height)
            }
            .background(Theme.bg)
        }
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    library.toggleFavorite(book)
                } label: {
                    Label(
                        library.isFavorite(book) ? "从书架删除" : "加入书架",
                        systemImage: library.isFavorite(book) ? "star.fill" : "star"
                    )
                    .font(Theme.metaSmall)
                }
                .tint(Theme.gold)
            }
        }
        .task { await load() }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(
                url: detail.cover.isEmpty ? book.cover : detail.cover,
                side: 100,
                radius: Theme.Radius.card
            )

            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(Theme.listTitle)
                    .foregroundColor(Theme.text1)
                    .lineLimit(3)

                let artist = detail.artist.isEmpty ? book.artist : detail.artist
                let author = detail.author.isEmpty ? book.author : detail.author

                HStack(spacing: 10) {
                    if !artist.isEmpty { Text("演播：\(artist)") }
                    if !author.isEmpty { Text("作者：\(author)") }
                }
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)

                if let source {
                    Text("来源：\(source.name)")
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text2)
                }

                if !detail.episodes.isEmpty {
                    Text("当前更新至 \(detail.episodes.count) 集")
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: 三列统计（真数据）

    private var stats: some View {
        HStack(spacing: 0) {
            statColumn(value: detail.episodes.isEmpty ? "—" : "\(detail.episodes.count)", label: "章节数")
            statColumn(
                value: listenedIndex.map { "第 \($0 + 1) 集" } ?? "未收听",
                label: "上次听到"
            )
            statColumn(value: source?.name ?? "—", label: "来源")
        }
        .padding(.vertical, 8)
    }

    private func statColumn(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Theme.statNumber)
                .foregroundColor(Theme.text1)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 简介（大字，默认 6 行）

    @ViewBuilder private var intro: some View {
        if !detail.intro.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(detail.intro)
                    .font(Theme.body)
                    .foregroundColor(Theme.text1)
                    .lineSpacing(5)
                    .lineLimit(introExpanded ? nil : 6)

                Button(introExpanded ? "收起" : "展开") {
                    withAnimation(.easeInOut(duration: 0.15)) { introExpanded.toggle() }
                }
                .font(Theme.metaSmall)
                .foregroundColor(Theme.accent)
            }
        }
    }

    // MARK: 常驻章节抽屉

    /// 常驻章节抽屉。**可以收起**（点右侧箭头，或往下拖）——
    /// 之前它不能隐藏，章节加载失败时就变成半屏空白挡着内容，真机上被当成"卡死"。
    private func drawer(viewport: CGFloat) -> some View {
        let minHeight = viewport * 0.28
        let maxHeight = viewport * 0.88
        let base = viewport * drawerFraction
        let expandedHeight = min(max(base - dragDelta, minHeight), maxHeight)
        let height = drawerCollapsed ? 62 : expandedHeight

        return VStack(spacing: 0) {
            // 抓手 + 当前集 + 收起/展开（拖动这里可以改抽屉高度，列表自身仍可正常滚动）
            VStack(spacing: 6) {
                Capsule()
                    .fill(Theme.separator)
                    .frame(width: 40, height: 4)

                HStack(spacing: 6) {
                    EpisodeDrawerHeader(
                        episodes: detail.episodes,
                        currentIndex: isCurrentBook ? player.index : nil
                    )

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { drawerCollapsed.toggle() }
                    } label: {
                        Image(systemName: drawerCollapsed ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.text2)
                            .frame(width: 32, height: 30)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Theme.Space.row)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($dragDelta) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        let projected = base - value.translation.height
                        // 往下拖过阈值 = 收起；往上拖 = 展开并记住新高度
                        if projected < viewport * 0.22 {
                            withAnimation(.easeInOut(duration: 0.18)) { drawerCollapsed = true }
                        } else {
                            drawerCollapsed = false
                            drawerFraction = min(max(projected / viewport, 0.28), 0.88)
                        }
                    }
            )

            if !drawerCollapsed {
                EpisodeDrawer(
                    episodes: detail.episodes,
                    currentIndex: isCurrentBook ? player.index : nil,
                    onSelect: { index in
                        player.play(book: book, episodes: detail.episodes, startAt: index)
                        // 起播不等待；剩余目录后台补齐（否则「下一集」会卡在第一页末尾）
                        Task { await fillQueueInBackground() }
                    },
                    hasMore: nextPage != nil,
                    loadingMore: loadingMore,
                    loadMoreFailed: loadMoreFailed,
                    onLoadMore: { Task { await loadMore() } }
                )
            }
        }
        .frame(height: height)
        .background(TopRoundedShape(radius: Theme.Radius.card).fill(Theme.surface))
    }

    // MARK: 取数

    private func load() async {
        guard let source else {
            errorText = "未知源"
            loading = false
            return
        }
        loading = true
        errorText = nil
        do {
            // 首屏只拉**一页**目录（大长篇一页就几十集，够看）。
            // 以前是一次拉完（2600 集 = 52 页）：既要等几十秒，又会因为高频请求被源站 429。
            // 必须带超时：源站挂住时不能永远停在「加载章节…」（真机反馈过"点进去卡死"）。
            let page = try await withTimeout(seconds: 25) {
                try await source.episodePage(for: book, page: 1, pages: 1)
            }
            var loaded = page.detail
            loaded.episodes = page.episodes
            detail = loaded
            nextPage = page.nextPage
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
        // 没有章节就把抽屉收起来：半屏空抽屉既没用又挡着内容，还容易被当成卡死
        if detail.episodes.isEmpty { drawerCollapsed = true }
    }

    /// 滑到章节列表底部时才拉下一页（「不滑动不加载」）
    private func loadMore() async {
        guard let source, let page = nextPage, !loadingMore else { return }
        loadingMore = true
        loadMoreFailed = false
        defer { loadingMore = false }
        do {
            let next = try await withTimeout(seconds: 25) {
                try await source.episodePage(for: book, page: page, pages: 1)
            }
            let known = Set(detail.episodes.map(\.url))
            detail.episodes.append(contentsOf: next.episodes.filter { !known.contains($0.url) })
            nextPage = next.nextPage
        } catch {
            // 失败就停在这一页，底部那行变成可点重试（自动重试会打转）
            loadMoreFailed = true
        }
    }

    /// 播放后**后台**把剩余目录拉齐塞进播放队列：
    /// 不阻塞起播，又不会让「下一集」卡在第一页末尾。
    private func fillQueueInBackground() async {
        guard let source else { return }
        var page = nextPage
        while let p = page {
            guard player.book?.bookURL == book.bookURL else { return }   // 用户换书了就停
            guard let next = try? await source.episodePage(for: book, page: p, pages: 2) else { return }
            let known = Set(detail.episodes.map(\.url))
            let fresh = next.episodes.filter { !known.contains($0.url) }
            detail.episodes.append(contentsOf: fresh)
            player.appendEpisodes(fresh)
            nextPage = next.nextPage
            page = next.nextPage
        }
    }
}

/// 只有上面两个角是圆的（`UnevenRoundedRectangle` 要 iOS 17，用不了）
struct TopRoundedShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
