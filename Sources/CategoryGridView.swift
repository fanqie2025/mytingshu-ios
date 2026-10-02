import SwiftUI

// MARK: - 分类网格页（设计 §6.2 的「更多」目的地）
//
// 4 列网格 + 触底加载。**不在这里声明 `.navigationDestination(for: Book.self)`**：
// 同一个 NavigationStack 里同一类型只能声明一次，Book 的跳转由 `DiscoverView` 根上统一声明。

struct CategoryGridView: View {
    let source: any BookSource
    let category: SourceCategory

    @State private var books: [Book] = []
    @State private var page = 1
    @State private var loading = false
    @State private var errorText: String?
    @State private var endReached = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Space.gridGap),
        count: 4
    )

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.sectionGap) {
                ForEach(books) { book in
                    NavigationLink(value: book) {
                        CoverGridCell(book: book, editing: false) {}
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if book.id == books.last?.id {
                            Task { await load() }
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.top, 12)

            if books.isEmpty && loading {
                StateView(kind: .loading, title: "正在加载…", message: nil, actionTitle: nil, action: nil)
                    .padding(.top, 60)
            }

            if let errorText {
                StateView(
                    kind: .error,
                    title: "加载失败",
                    message: errorText,
                    actionTitle: "重试",
                    action: { Task { await load() } }
                )
            }

            if endReached && !books.isEmpty {
                Text("没有更多了")
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.text2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }

            if loading && !books.isEmpty {
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
        }
        .background(Theme.bg)
        // 本页由 `.toolbar(.hidden)` 的发现页 push 进来，显式恢复导航栏才拿得到返回按钮
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if books.isEmpty { await load() }
        }
    }

    private func load() async {
        guard !loading, !endReached else { return }
        loading = true
        errorText = nil
        do {
            let list = try await withTimeout(seconds: 20) {
                try await offMain { try await source.books(in: category, page: page) }
            }
            let fresh = list.filter { candidate in
                !books.contains(where: { $0.bookURL == candidate.bookURL })
            }
            books.append(contentsOf: fresh)
            page += 1
            if list.isEmpty || fresh.isEmpty { endReached = true }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        loading = false
    }
}
