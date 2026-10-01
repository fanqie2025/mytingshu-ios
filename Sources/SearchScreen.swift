import SwiftUI
import UIKit

// MARK: - 搜索页（设计 §6.3，截图 02）
//
// 顶部胶囊输入框 + 「取消」→ 结果**扁平列表**（不按源分组）
// 与唔语的有意偏差：每行多显示一个小字**源名**（唔语是单后端所以不标源，我们多源必须能区分）
// 搜索逻辑逐字沿用原 `SearchView.runSearch()`：TaskGroup 并发 + 每源 20 秒超时
// 保留并复用 UI.swift 里的 `SearchGroup` / `SourceErrorItem` / `VerifyTarget` / `VerificationSheet`

struct SearchScreen: View {
    @ObservedObject private var settings = SourceSettings.shared
    @ObservedObject private var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var results: [SearchGroup] = []
    @State private var errors: [SourceErrorItem] = []
    @State private var searching = false
    @State private var showErrors = false
    @State private var verifyTarget: VerifyTarget?
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                searchBar
                Rectangle()
                    .fill(Theme.separator)
                    .frame(height: 0.5)
                content
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Book.self) { book in
                DetailView(book: book)
            }
            .sheet(item: $verifyTarget) { target in
                VerificationSheet(source: target.source, keyword: target.keyword) {
                    Task { await runSearch() }
                }
            }
        }
    }

    // MARK: 顶部搜索框

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.accent)

                TextField("", text: $keyword)
                    .font(Theme.meta)
                    .foregroundColor(Theme.text1)
                    .tint(Theme.accent)
                    .submitLabel(.search)
                    .onSubmit { Task { await runSearch() } }
                    .overlay(alignment: .leading) {
                        if keyword.isEmpty {
                            Text("点击搜索，支持搜书、分类、演播者等")
                                .font(Theme.meta)
                                .foregroundColor(Theme.text2)
                                .allowsHitTesting(false)
                        }
                    }

                if !keyword.isEmpty {
                    Button {
                        keyword = ""; results = []; errors = []; showErrors = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Theme.text2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))

            Button("取消") { dismiss() }
                .font(Theme.meta)
                .foregroundColor(Theme.accent)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 10)
    }

    // MARK: 内容

    @ViewBuilder private var content: some View {
        if searching && results.isEmpty {
            StateView(
                kind: .loading,
                title: "正在搜索 \(settings.enabledSources.count) 个源…",
                message: nil,
                actionTitle: nil,
                action: nil
            )
            .padding(.top, 60)
        } else if results.isEmpty && errors.isEmpty {
            StateView(
                kind: .empty,
                title: keyword.isEmpty ? "输入关键词开始搜索" : "没有搜到结果",
                message: keyword.isEmpty ? nil : "换个关键词，或到「我的 → 源管理」检查源是否可用",
                actionTitle: nil,
                action: nil
            )
            .padding(.top, 60)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(results) { group in
                        ForEach(group.books) { book in
                            Button {
                                path.append(book)
                            } label: {
                                SearchResultRow(book: book, sourceName: group.source.name)
                            }
                            .buttonStyle(.plain)
                            // 唔语行为：长按列表项加入书架
                            .onLongPressGesture { library.toggleFavorite(book) }
                        }
                    }

                    if !errors.isEmpty { failedSources }
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 12)
                .padding(.bottom, 30)
            }
        }
    }

    /// 没搜到的源：折叠成一行，展开看原因与「去验证」
    private var failedSources: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showErrors.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("没搜到的源 (\(errors.count))")
                        .font(Theme.meta)
                        .foregroundColor(Theme.text2)
                    Image(systemName: showErrors ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.text2)
                }
            }
            .buttonStyle(.plain)

            if showErrors {
                ForEach(errors) { item in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(Theme.metaSmall)
                                .foregroundColor(Theme.text1)
                            Text(item.message)
                                .font(Theme.metaSmall)
                                .foregroundColor(Theme.text2)
                                .lineLimit(3)
                        }
                        Spacer(minLength: 8)
                        if item.needsVerify {
                            Button("去验证") {
                                verifyTarget = VerifyTarget(source: item.source, keyword: keyword)
                            }
                            .font(Theme.metaSmall)
                            .foregroundColor(Theme.accent)
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: 搜索（逻辑沿用原实现）

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func runSearch() async {
        guard !keyword.isEmpty, !searching else { return }
        dismissKeyboard()
        searching = true
        results = []; errors = []; showErrors = false
        let kw = keyword
        let sources = settings.enabledSources.filter { $0.searchable }

        await withTaskGroup(of: (any BookSource, Result<[Book], Error>).self) { group in
            for source in sources {
                group.addTask {
                    do {
                        // 单个源最多等 20 秒，避免卡住的源拖住整个搜索
                        let books = try await withTimeout(seconds: 20) {
                            try await source.search(keyword: kw, page: 1)
                        }
                        return (source, .success(books))
                    } catch {
                        return (source, .failure(error))
                    }
                }
            }

            for await (source, result) in group {
                switch result {
                case .success(let books):
                    if !books.isEmpty { results.append(SearchGroup(source: source, books: books)) }
                case .failure(let error):
                    let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    errors.append(
                        SourceErrorItem(source: source, message: message, needsVerify: message.contains("验证"))
                    )
                }
            }
        }

        results.sort { $0.source.name < $1.source.name }
        searching = false
    }
}
