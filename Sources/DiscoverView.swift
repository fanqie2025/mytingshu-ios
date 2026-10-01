import SwiftUI

// MARK: - 发现页（设计 §6.2，截图 05）
//
// 唔语这页（它叫「热榜」）的「热榜 / 最近更新」是它服务端下发的内容；我们**没有服务端**，
// 所以改为**源驱动**：源分段条 → 分类宫格 → 每个分类一个横向 Carousel（最多 4 个）。
// 并发上限 2、单请求 20 秒超时、结果内存缓存 5 分钟（设计 §6.2 + 评审聚焦 5）
//
// 并发安全（独立评审修复）：`reload()` 有**代际号**，所有 `await` 之后一律
// ① 先校验代际 ② 再按 id 重新定位数组下标；循环切片只对**快照**取下标。
// 原因：源分段条/下拉刷新/重试都能在挂起期间触发第二次 reload，而 `sections` 会被整体重建，
// 用旧的 `count`/`index` 取下标会 `Range requires lowerBound <= upperBound` 或 `Index out of range`。

// MARK: 数据

private struct DiscoverSection: Identifiable {
    var id: String { category.url }
    let category: SourceCategory
    var books: [Book] = []
    var error: String?
}

/// 5 分钟内存缓存：切页签回来不重抓
private enum DiscoverCache {
    private static var store: [String: (Date, [Book])] = [:]
    private static let ttl: TimeInterval = 300

    static func books(_ key: String) -> [Book]? {
        guard let hit = store[key], Date().timeIntervalSince(hit.0) < ttl else { return nil }
        return hit.1
    }

    static func put(_ key: String, _ books: [Book]) {
        store[key] = (Date(), books)
    }
}

private func discoverCacheKey(_ sourceId: String, _ url: String) -> String {
    sourceId + "|" + url
}

/// 「更多」用：分类网格页的路由（Book 用 value-based NavigationLink，见 Components.swift 顶部说明）
private enum DiscoverRoute: Hashable {
    case category(sourceId: String, title: String, url: String)
}

// MARK: 页面

struct DiscoverView: View {
    /// 空态里的「去导入书源」要切到「我的」页签 —— 由 RootView 注入（给了默认值，`DiscoverView()` 仍可用）
    var onGoToMine: () -> Void = {}

    @ObservedObject private var settings = SourceSettings.shared

    @State private var path = NavigationPath()
    @State private var sourceIndex = 0
    @State private var menus: [CategoryMenu] = []
    @State private var sections: [DiscoverSection] = []
    @State private var loadingMenus = false
    @State private var menusError: String?
    /// 取数代际：重叠的 reload/load 用它丢弃跨代结果
    @State private var generation = 0

    private let categoryColumns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Space.row),
        count: 3
    )

    /// 只列**能按分类浏览**的源（`BookSource.discoverable`）。
    /// 不加这个过滤，275听书 / 爱听书 / 13听书网 / 酷我畅听 这些只有搜索入口的源会出现在分段条里，
    /// 点进去要么报「分类获取失败」要么一片空白（用户真机截图里 ABS 那一栏就是这种形态）。
    private var sources: [any BookSource] { settings.enabledSources.filter { $0.discoverable } }

    private var currentSource: (any BookSource)? {
        if sources.indices.contains(sourceIndex) { return sources[sourceIndex] }
        return sources.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if settings.enabledSources.isEmpty {
                        StateView(
                            kind: .empty,
                            title: "还没有启用任何源",
                            message: "去「我的 → 源管理」导入或启用书源",
                            actionTitle: "去导入书源",
                            action: { onGoToMine() }
                        )
                        .padding(.top, 80)
                    } else if sources.isEmpty {
                        StateView(
                            kind: .empty,
                            title: "没有可按分类浏览的源",
                            message: "已启用的源都只能搜索找书；去「书架」顶部的搜索框，或在「我的 → 源管理」再启用带分类的源",
                            actionTitle: "去源管理",
                            action: { onGoToMine() }
                        )
                        .padding(.top, 80)
                    } else {
                        sourcePicker

                        if loadingMenus && sections.isEmpty {
                            StateView(kind: .loading, title: "正在获取分类…", message: nil, actionTitle: nil, action: nil)
                        } else if let menusError {
                            StateView(
                                kind: .error,
                                title: "分类获取失败",
                                message: menusError,
                                actionTitle: "重试",
                                action: { Task { await reload() } }
                            )
                        } else if menus.isEmpty {
                            StateView(
                                kind: .empty,
                                title: "这个源没有分类",
                                message: "它只能通过搜索找书：去「书架」顶部的搜索框",
                                actionTitle: nil,
                                action: nil
                            )
                        } else {
                            categoryGrid
                            ForEach(sections) { section in
                                sectionView(section)
                            }
                        }
                    }
                }
                .padding(.vertical, 14)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await reload() }
            .navigationDestination(for: Book.self) { book in
                DetailView(book: book)
            }
            .navigationDestination(for: DiscoverRoute.self) { route in
                switch route {
                case .category(let sourceId, let title, let url):
                    if let src = SourceRegistry.source(withId: sourceId) {
                        CategoryGridView(source: src, category: SourceCategory(title: title, url: url))
                    } else {
                        StateView(kind: .error, title: "这个源已失效", message: "去「我的 → 源管理」检查一下", actionTitle: nil, action: nil)
                    }
                }
            }
            .task { await reload() }
            .onChange(of: sourceIndex) { _ in Task { await reload() } }
        }
    }

    // MARK: 源分段条

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.row) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, src in
                    Button {
                        sourceIndex = index
                    } label: {
                        Text(src.name)
                            .font(Theme.meta)
                            .foregroundColor(index == sourceIndex ? Theme.text1 : Theme.text2)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                Capsule().fill(index == sourceIndex ? Theme.accent.opacity(0.3) : Theme.surface)
                            )
                            .overlay(
                                Capsule().stroke(index == sourceIndex ? Theme.accent : Theme.surface, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Space.page)
        }
    }

    // MARK: 分类宫格

    private var categoryGrid: some View {
        // 上限 30：当前分类最多的源是 22听书（24 个），30 覆盖得住；
        // 原来写 12 会**静默丢掉**一半分类，超过 30 的源出现时再加「全部」入口
        let categories = dedupedCategories(limit: 30)
        return Group {
            if !categories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("分类")
                        .font(Theme.sectionTitle)
                        .foregroundColor(Theme.text1)
                        .padding(.horizontal, Theme.Space.page)

                    LazyVGrid(columns: categoryColumns, alignment: .leading, spacing: Theme.Space.row) {
                        ForEach(categories) { category in
                            if let src = currentSource {
                                NavigationLink {
                                    CategoryGridView(source: src, category: category)
                                } label: {
                                    HStack {
                                        Text(category.title)
                                            .font(Theme.metaSmall)
                                            .foregroundColor(Theme.text1)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                                    .background(
                                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                            .fill(Theme.surface)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, Theme.Space.page)
                }
            }
        }
    }

    // MARK: 每个分类一栏

    @ViewBuilder
    private func sectionView(_ section: DiscoverSection) -> some View {
        if let error = section.error {
            VStack(alignment: .leading, spacing: 8) {
                Text(section.category.title)
                    .font(Theme.sectionTitle)
                    .foregroundColor(Theme.text1)
                HStack(spacing: 10) {
                    Text(error)
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text2)
                        .lineLimit(2)
                    Button("重试") { Task { await load(sectionId: section.id) } }
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Space.page)
        } else if section.books.isEmpty {
            // 还没回来的分类给骨架，而不是一条空栏（评审聚焦 5）
            skeletonCarousel(title: section.category.title)
        } else {
            CarouselSection(title: section.category.title, books: section.books) {
                guard let src = currentSource else { return }
                path.append(
                    DiscoverRoute.category(
                        sourceId: src.id,
                        title: section.category.title,
                        url: section.category.url
                    )
                )
            }
        }
    }

    /// 取数中的骨架：四个灰块
    private func skeletonCarousel(title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Theme.sectionTitle)
                .foregroundColor(Theme.text2)
                .padding(.horizontal, Theme.Space.page)

            HStack(spacing: Theme.Space.gridGap) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Theme.Radius.coverGrid, style: .continuous)
                        .fill(Theme.surface)
                        .frame(width: 92, height: 92)
                }
            }
            .padding(.horizontal, Theme.Space.page)
        }
    }

    // MARK: 取数

    /// 展平分类并按 URL 去重（`SourceCategory.id` 就是 url；重复 id 会让 ForEach 行为未定义）
    private func dedupedCategories(limit: Int) -> [SourceCategory] {
        var seen = Set<String>()
        var result: [SourceCategory] = []
        for category in menus.flatMap(\.categories) where !seen.contains(category.url) {
            seen.insert(category.url)
            result.append(category)
            if result.count >= limit { break }
        }
        return result
    }

    private func reload() async {
        generation += 1
        let gen = generation

        guard let src = currentSource else {
            menus = []; sections = []; menusError = nil
            return
        }
        menusError = nil
        loadingMenus = true
        do {
            let fetched = try await withTimeout(seconds: 20) { try await src.menus() }
            guard gen == generation else { return }   // 期间又 reload 过 → 丢弃这一代
            menus = fetched
        } catch {
            guard gen == generation else { return }
            menus = []
            menusError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loadingMenus = false

        // 快照：循环里只对快照取下标，绝不在 await 之后读 @State 数组
        let snapshot = dedupedCategories(limit: 4).map { DiscoverSection(category: $0) }
        sections = snapshot

        // 并发上限 2：每批两个，批间串行（评审聚焦 5）
        for start in stride(from: 0, to: snapshot.count, by: 2) {
            guard gen == generation else { return }
            let slice = Array(snapshot[start..<min(start + 2, snapshot.count)])

            await withTaskGroup(of: (String, Result<[Book], Error>).self) { group in
                for item in slice {
                    let key = discoverCacheKey(src.id, item.category.url)

                    if let cached = DiscoverCache.books(key) {
                        apply(books: cached, sourceId: src.id, sectionId: item.id, generation: gen)
                        continue
                    }

                    group.addTask {
                        do {
                            let books = try await withTimeout(seconds: 20) {
                                try await src.books(in: item.category, page: 1)
                            }
                            return (item.id, .success(books))
                        } catch {
                            return (item.id, .failure(error))
                        }
                    }
                }

                for await (id, result) in group {
                    switch result {
                    case .success(let books):
                        apply(books: books, sourceId: src.id, sectionId: id, generation: gen)
                    case .failure(let error):
                        apply(
                            error: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                            sectionId: id,
                            generation: gen
                        )
                    }
                }
            }
        }
    }

    /// 单栏重试：先把分类抓到局部再 await，回来后按 id 重新定位
    private func load(sectionId: String) async {
        let gen = generation
        guard let src = currentSource,
              let item = sections.first(where: { $0.id == sectionId }) else { return }

        let category = item.category
        if let index = sections.firstIndex(where: { $0.id == sectionId }) {
            sections[index].error = nil
        }

        do {
            let books = try await withTimeout(seconds: 20) {
                try await src.books(in: category, page: 1)
            }
            apply(books: books, sourceId: src.id, sectionId: sectionId, generation: gen)
        } catch {
            apply(
                error: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                sectionId: sectionId,
                generation: gen
            )
        }
    }

    // MARK: 落地（一律先校验代际，再按 id 重新定位）

    private func apply(books: [Book], sourceId: String, sectionId: String, generation gen: Int) {
        guard gen == generation, let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[index].books = books
        DiscoverCache.put(discoverCacheKey(sourceId, sections[index].category.url), books)
    }

    private func apply(error message: String, sectionId: String, generation gen: Int) {
        guard gen == generation, let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[index].error = message
    }
}
