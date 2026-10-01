import SwiftUI

// MARK: - 发现页（设计 §6.2，截图 05）
//
// 唔语这页（它叫「热榜」）的「热榜 / 最近更新」是它服务端下发的内容；我们**没有服务端**，
// 所以改为**源驱动**：源分段条 → 分类宫格 → 每个分类一个横向 Carousel（最多 4 个）。
// 并发上限 2、单请求 20 秒超时、结果内存缓存 5 分钟（设计 §6.2 + 评审聚焦 5）

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
    @ObservedObject private var settings = SourceSettings.shared

    @State private var path = NavigationPath()
    @State private var sourceIndex = 0
    @State private var menus: [CategoryMenu] = []
    @State private var sections: [DiscoverSection] = []
    @State private var loadingMenus = false
    @State private var menusError: String?

    private let categoryColumns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Space.row),
        count: 3
    )

    private var sources: [any BookSource] { settings.enabledSources }

    private var currentSource: (any BookSource)? {
        if sources.indices.contains(sourceIndex) { return sources[sourceIndex] }
        return sources.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if sources.isEmpty {
                        StateView(
                            kind: .empty,
                            title: "还没有启用任何源",
                            message: "去「我的 → 源管理」导入或启用书源",
                            actionTitle: nil,
                            action: nil
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
                // T9: 接 DetailView(book: book)
                Text("详情页待接：\(book.title)")
                    .font(Theme.meta)
                    .foregroundColor(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
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
        let categories = Array(menus.flatMap(\.categories).prefix(12))
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
                                        RoundedRectangle(cornerRadius: Theme.Space.row, style: .continuous)
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

    // MARK: 取数

    private func reload() async {
        guard let src = currentSource else {
            menus = []; sections = []; menusError = nil
            return
        }
        menusError = nil
        loadingMenus = true
        do {
            menus = try await withTimeout(seconds: 20) { try await src.menus() }
        } catch {
            menus = []
            menusError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loadingMenus = false

        let categories = Array(menus.flatMap(\.categories).prefix(4))
        sections = categories.map { DiscoverSection(category: $0) }

        // 并发上限 2：每批两个，批间串行（评审聚焦 5）
        for start in stride(from: 0, to: sections.count, by: 2) {
            let slice = Array(sections[start..<min(start + 2, sections.count)])

            await withTaskGroup(of: (String, Result<[Book], Error>).self) { group in
                for item in slice {
                    let key = discoverCacheKey(src.id, item.category.url)

                    if let cached = DiscoverCache.books(key) {
                        if let index = sections.firstIndex(where: { $0.id == item.id }) {
                            sections[index].books = cached
                        }
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
                    guard let index = sections.firstIndex(where: { $0.id == id }) else { continue }
                    switch result {
                    case .success(let books):
                        sections[index].books = books
                        DiscoverCache.put(discoverCacheKey(src.id, sections[index].category.url), books)
                    case .failure(let error):
                        sections[index].error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    }
                }
            }
        }
    }

    private func load(sectionId: String) async {
        guard let src = currentSource,
              let index = sections.firstIndex(where: { $0.id == sectionId }) else { return }
        sections[index].error = nil
        do {
            let books = try await withTimeout(seconds: 20) {
                try await src.books(in: sections[index].category, page: 1)
            }
            sections[index].books = books
            DiscoverCache.put(discoverCacheKey(src.id, sections[index].category.url), books)
        } catch {
            sections[index].error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }
}
