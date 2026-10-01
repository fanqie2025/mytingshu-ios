import SwiftUI
import UIKit
import WebKit

// MARK: - 迷你播放条

struct MiniPlayerBar: View {
    @ObservedObject var player = PlayerEngine.shared
    @State private var showFull = false

    var body: some View {
        if let book = player.book, let ep = player.currentEpisode {
            Button { showFull = true } label: {
                HStack(spacing: 12) {
                    AsyncImage(url: URL(string: book.cover)) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.orange.opacity(0.2)
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(ep.title.isEmpty ? book.title : ep.title)
                            .font(.subheadline).lineLimit(1)
                        Text(book.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial)
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showFull) { PlayerView() }
        }
    }
}

// MARK: - 书源

struct HomeView: View {
    @ObservedObject var settings = SourceSettings.shared
    @State private var showSettings = false

    var body: some View {
        NavigationView {
            List {
                ForEach(settings.enabledSources, id: \.id) { src in
                    NavigationLink(destination: SourceBrowseView(source: src)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(src.name).font(.headline)
                            Text(src.host).font(.caption).foregroundColor(.secondary)
                            if !src.desc.isEmpty {
                                Text(src.desc).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                if settings.enabledSources.isEmpty {
                    Text("还没有启用任何源，去「设置 → 源管理」里打开。")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("书源")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
        }
        .navigationViewStyle(.stack)
    }
}

struct SourceBrowseView: View {
    let source: any BookSource
    @State private var menus: [CategoryMenu] = []
    @State private var selected: SourceCategory?
    @State private var books: [Book] = []
    @State private var page = 1
    @State private var loading = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            if !menus.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(menus.flatMap(\.categories)) { c in
                            Button {
                                selected = c; page = 1; books = []; Task { await load() }
                            } label: {
                                Text(c.title)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(selected?.url == c.url ? Color.orange : Color(.secondarySystemBackground))
                                    .foregroundColor(selected?.url == c.url ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                Divider()
            }
            List {
                ForEach(books) { b in
                    NavigationLink(destination: BookDetailView(book: b)) { BookRow(book: b) }
                }
                if loading { HStack { Spacer(); ProgressView(); Spacer() } }
                if let errorText { Text(errorText).foregroundColor(.red).font(.footnote) }
            }
            .listStyle(.plain)
        }
        .navigationTitle(source.name)
        .task {
            if menus.isEmpty {
                menus = (try? await source.menus()) ?? []
                if let first = menus.first?.categories.first { selected = first }
            }
            await load()
        }
    }

    private func load() async {
        guard let cat = selected, !loading else { return }
        loading = true; errorText = nil
        do {
            let list = try await source.books(in: cat, page: page)
            books.append(contentsOf: list.filter { b in !books.contains(where: { $0.bookURL == b.bookURL }) })
            page += 1
        } catch { errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        loading = false
    }
}

struct BookRow: View {
    let book: Book
    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: URL(string: book.cover)) { img in
                img.resizable().aspectRatio(contentMode: .fill)
            } placeholder: { Color(.secondarySystemBackground) }
            .frame(width: 56, height: 74).clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(book.title).font(.subheadline).lineLimit(2)
                if !book.artist.isEmpty { Text("播音：\(book.artist)").font(.caption).foregroundColor(.secondary) }
                else if !book.author.isEmpty { Text("作者：\(book.author)").font(.caption).foregroundColor(.secondary) }
                if !book.intro.isEmpty {
                    Text(book.intro).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 搜索

struct SearchGroup: Identifiable {
    var id: String { source.id }
    let source: any BookSource
    let books: [Book]
}

struct SourceErrorItem: Identifiable {
    var id: String { source.id }
    let source: any BookSource
    let message: String
    let needsVerify: Bool
    var name: String { source.name }
}

struct VerifyTarget: Identifiable {
    var id: String { source.id + "|" + keyword }
    let source: any BookSource
    let keyword: String
}

struct SearchView: View {
    @ObservedObject var settings = SourceSettings.shared
    @State private var keyword = ""
    @State private var results: [SearchGroup] = []
    @State private var errors: [SourceErrorItem] = []
    @State private var searching = false
    @State private var verifyTarget: VerifyTarget?

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack {
                        TextField("书名 / 作者 / 播音", text: $keyword)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await runSearch() } }
                        if !keyword.isEmpty {
                            Button {
                                keyword = ""; results = []; errors = []
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        Button("搜索") { Task { await runSearch() } }
                            .disabled(keyword.isEmpty || searching)
                    }
                    if searching { HStack { ProgressView(); Text("正在搜索 \(settings.enabledSources.count) 个源…").font(.footnote) } }
                }
                ForEach(results) { group in
                    Section("\(group.source.name)（\(group.books.count)）") {
                        ForEach(group.books) { b in
                            NavigationLink(destination: BookDetailView(book: b)) { BookRow(book: b) }
                        }
                    }
                }
                if !errors.isEmpty {
                    Section("没搜到的源") {
                        ForEach(errors) { e in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(e.name).font(.footnote)
                                    Text(e.message).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if e.needsVerify {
                                    Button("去验证") {
                                        verifyTarget = VerifyTarget(source: e.source, keyword: keyword)
                                    }
                                    .font(.footnote)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("搜索")
            .sheet(item: $verifyTarget) { t in
                VerificationSheet(source: t.source, keyword: t.keyword) {
                    Task { await runSearch() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func runSearch() async {
        guard !keyword.isEmpty, !searching else { return }
        dismissKeyboard()
        searching = true
        results = []; errors = []
        let kw = keyword
        let sources = settings.enabledSources.filter { $0.searchable }
        await withTaskGroup(of: (any BookSource, Result<[Book], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do {
                        // 单个源最多等 20 秒，避免卡住的源拖住整个搜索
                        let books = try await withTimeout(seconds: 20) {
                            try await s.search(keyword: kw, page: 1)
                        }
                        return (s, .success(books))
                    } catch {
                        return (s, .failure(error))
                    }
                }
            }
            for await (s, r) in group {
                switch r {
                case .success(let books):
                    if !books.isEmpty { results.append(SearchGroup(source: s, books: books)) }
                case .failure(let e):
                    let msg = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                    errors.append(SourceErrorItem(source: s, message: msg, needsVerify: msg.contains("验证")))
                }
            }
        }
        results.sort { $0.source.name < $1.source.name }
        searching = false
    }
}

// MARK: - 验证码 WebView

struct VerificationSheet: View {
    let source: any BookSource
    let keyword: String
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if let url = source.verificationURL(keyword: keyword) {
                    WebView(url: url) { cookies in
                        HTTPClient.injectCookies(from: cookies)
                    }
                } else {
                    Text("该源没有提供验证地址").foregroundColor(.secondary)
                }
            }
            .navigationTitle("\(source.name) 验证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss(); onDone() }
                }
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    var onCookies: ([HTTPCookie]) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: .zero, configuration: cfg)
        context.coordinator.web = web
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCookies: onCookies) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        let onCookies: ([HTTPCookie]) -> Void
        init(onCookies: @escaping ([HTTPCookie]) -> Void) { self.onCookies = onCookies }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                self?.onCookies(cookies)
            }
        }
    }
}

// MARK: - 书籍详情 / 章节

struct BookDetailView: View {
    let book: Book
    @State private var detail = BookDetail()
    @State private var loading = true
    @State private var errorText: String?
    @ObservedObject private var library = LibraryStore.shared

    private var source: (any BookSource)? { SourceRegistry.source(withId: book.sourceId) }

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    AsyncImage(url: URL(string: detail.cover.isEmpty ? book.cover : detail.cover)) { img in
                        img.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: { Color(.secondarySystemBackground) }
                    .frame(width: 92, height: 122).clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.title).font(.headline)
                        if !detail.author.isEmpty { Text("作者：\(detail.author)").font(.caption) }
                        if !detail.artist.isEmpty { Text("播音：\(detail.artist)").font(.caption) }
                        Text("章节：\(detail.episodes.count)").font(.caption)
                        HStack {
                            Button {
                                PlayerEngine.shared.play(book: book, episodes: detail.episodes, startAt: 0)
                            } label: { Label("播放", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                                .disabled(detail.episodes.isEmpty)
                            Button {
                                library.toggleFavorite(book)
                            } label: {
                                Image(systemName: library.isFavorite(book) ? "heart.fill" : "heart")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                if !detail.intro.isEmpty {
                    Text(detail.intro).font(.caption).foregroundColor(.secondary)
                }
            }
            Section("章节") {
                if loading { HStack { ProgressView(); Text("加载章节…") } }
                if let errorText { Text(errorText).foregroundColor(.red).font(.footnote) }
                ForEach(detail.episodes.indices, id: \.self) { i in
                    let ep = detail.episodes[i]
                    Button {
                        PlayerEngine.shared.play(book: book, episodes: detail.episodes, startAt: i)
                    } label: {
                        HStack {
                            Text(ep.title.isEmpty ? "第 \(i + 1) 集" : ep.title).font(.subheadline).lineLimit(1)
                            Spacer()
                            Image(systemName: "play.circle").foregroundColor(.orange)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let source else { errorText = "未知源"; loading = false; return }
        loading = true
        do { detail = try await source.detail(for: book) }
        catch { errorText = (error as? LocalizedError)?.errorDescription ?? "\(error)" }
        loading = false
    }
}

// MARK: - 收藏 / 历史

struct FavoritesView: View {
    @ObservedObject private var library = LibraryStore.shared
    var body: some View {
        NavigationView {
            List {
                ForEach(library.favorites) { b in
                    NavigationLink(destination: BookDetailView(book: b)) { BookRow(book: b) }
                }
                if library.favorites.isEmpty { Text("还没有收藏").foregroundColor(.secondary) }
            }
            .navigationTitle("收藏")
        }
        .navigationViewStyle(.stack)
    }
}

struct HistoryView: View {
    @ObservedObject private var library = LibraryStore.shared
    var body: some View {
        NavigationView {
            List {
                ForEach(library.history) { h in
                    Button {
                        Task {
                            guard let src = SourceRegistry.source(withId: h.book.sourceId) else { return }
                            if let d = try? await src.detail(for: h.book) {
                                PlayerEngine.shared.play(book: h.book, episodes: d.episodes, startAt: h.episodeIndex)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.book.title).font(.subheadline)
                            Text("听到：\(h.episodeTitle.isEmpty ? "第 \(h.episodeIndex + 1) 集" : h.episodeTitle)")
                                .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
                if library.history.isEmpty { Text("还没有收听记录").foregroundColor(.secondary) }
            }
            .navigationTitle("历史")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") { library.clearHistory() }.disabled(library.history.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 设置（含源管理）

struct SettingsView: View {
    @ObservedObject var settings = SourceSettings.shared
    @ObservedObject var store = SourceStore.shared
    @ObservedObject var player = PlayerEngine.shared
    @ObservedObject var cache = CacheManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var showRate = false
    @State private var showSleep = false
    @State private var showDiag = false
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importMsg = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            List {
                Section("源管理") {
                    ForEach(store.all, id: \.id) { src in
                        Toggle(isOn: Binding(
                            get: { settings.enabled.contains(src.id) },
                            set: { on in
                                if on { settings.enabled.insert(src.id) } else { settings.enabled.remove(src.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(src.name)
                                    Text(src.host).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                    }
                    Button {
                        showImport = true
                    } label: {
                        Label("导入书源（JSON / 订阅地址）", systemImage: "plus.circle")
                    }
                }

                if !store.imported.isEmpty {
                    Section("我导入的源") {
                        ForEach(store.imported) { r in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(r.name)
                                    Text(r.host).font(.caption2).foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { store.remove(id: r.id) } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                Section("播放") {
                    Picker("跳过片头", selection: Binding(
                        get: { Int(player.skipIntro) },
                        set: { player.skipIntro = Double($0) })) {
                        Text("不跳过").tag(0); Text("5 秒").tag(5); Text("10 秒").tag(10)
                        Text("15 秒").tag(15); Text("30 秒").tag(30); Text("45 秒").tag(45); Text("60 秒").tag(60)
                    }
                    Picker("跳过片尾", selection: Binding(
                        get: { Int(player.skipOutro) },
                        set: { player.skipOutro = Double($0) })) {
                        Text("不跳过").tag(0); Text("5 秒").tag(5); Text("10 秒").tag(10)
                        Text("15 秒").tag(15); Text("30 秒").tag(30); Text("45 秒").tag(45); Text("60 秒").tag(60)
                    }
                    HStack(spacing: 10) {
                        Text("倍速").font(.subheadline)
                        Slider(value: Binding(get: { Double(player.rate) },
                                              set: { player.setRate(Float(($0 * 100).rounded() / 100)) }),
                               in: 0.5...3.0, step: 0.05)
                        Text(rateLabel(player.rate)).font(.caption).monospacedDigit().frame(width: 50)
                    }
                    HStack {
                        Text("定时关闭")
                        Spacer()
                        Button(player.sleepDeadline == nil ? "关闭" : sleepTitle) { showSleep = true }
                            .foregroundColor(.orange)
                    }
                }

                Section("缓存") {
                    Picker("自动缓存下集", selection: Binding(
                        get: { CacheManager.shared.autoCacheNext },
                        set: { CacheManager.shared.autoCacheNext = $0 })) {
                        Text("关闭").tag(0)
                        Text("缓存 1 集").tag(1)
                        Text("缓存 2 集").tag(2)
                        Text("缓存 3 集").tag(3)
                    }
                    HStack {
                        Text("已缓存占用")
                        Spacer()
                        Text(cache.sizeText()).foregroundColor(.secondary)
                    }
                    Button("清空缓存", role: .destructive) { cache.clearAll() }
                        .disabled(cache.cachedKeys.isEmpty)
                }

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text("0.1.0").foregroundColor(.secondary) }
                    HStack { Text("源数量"); Spacer(); Text("\(settings.enabledSources.count)/\(store.all.count)").foregroundColor(.secondary) }
                    Button("诊断 / 源测试") { showDiag = true }
                    Text("本 App 只做播放器，内容来自各听书站；音频版权归原站所有。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showImport) { importSheet }
            .sheet(isPresented: $showSleep) { SleepSheet() }
            .sheet(isPresented: $showDiag) { DiagnosticsView() }
        }
    }

    private var sleepTitle: String {
        guard let d = player.sleepDeadline else { return "关闭" }
        return "\(max(0, Int(d.timeIntervalSinceNow / 60))) 分钟后"
    }

    private var importSheet: some View {
        NavigationView {
            Form {
                Section("粘贴订阅地址（推荐）") {
                    TextField("https://…/sources.json", text: $importURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button {
                        Task { await doImportURL() }
                    } label: { busy ? AnyView(ProgressView()) : AnyView(Text("从地址导入")) }
                    .disabled(importURL.isEmpty || busy)
                }
                Section("或直接粘贴书源 JSON") {
                    TextEditor(text: $importText)
                        .frame(minHeight: 160)
                        .font(.system(.caption, design: .monospaced))
                    Button("导入这段 JSON") { doImportText() }
                        .disabled(importText.isEmpty || busy)
                }
                if !importMsg.isEmpty {
                    Section("结果") { Text(importMsg).font(.footnote) }
                }
                Section {
                    Text("""
                    书源 JSON 格式（字段都可选，够用即可）：
                    {
                      "id": "ting29",
                      "name": "29听书网",
                      "host": "https://m.ting29.com",
                      "encoding": "utf-8",
                      "search": {
                        "url": "{host}/search.php?searchword={kw}&page={page}",
                        "list": "ul.row-b > li",
                        "title": "h2 a.f-bold@text",
                        "urlRule": "h2 a.f-bold@href",
                        "cover": "img@src",
                        "artist": "span.fr@text",
                        "intro": "p.f-gray@text"
                      },
                      "categories": [{"title":"玄幻","url":"{host}/html/221.html"}],
                      "detail": {
                        "episodes": "#yuedu ul.ul-36 li a",
                        "episodeTitle": "@title",
                        "episodeUrl": "@href",
                        "intro": "p.f-gray@text"
                      },
                      "audio": {"type":"regex","pattern":"var\\s+now\\s*=\\s*\\"([^\\"]+)\\""},
                      "verification": {"url":"{host}/search.php?searchword={kw}"}
                    }
                    """)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("导入书源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showImport = false } }
            }
        }
    }

    private func doImportText() {
        busy = true
        do {
            let names = try store.importJSON(importText)
            settings.enableNewSources()
            importMsg = "✅ 导入成功：\(names.joined(separator: "、"))"
            importText = ""
        } catch {
            importMsg = "❌ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        busy = false
    }

    private func doImportURL() async {
        busy = true
        do {
            let names = try await store.importURL(importURL)
            settings.enableNewSources()
            importMsg = "✅ 导入成功：\(names.joined(separator: "、"))"
            importURL = ""
        } catch {
            importMsg = "❌ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        busy = false
    }

    private var sleepTag: Int {
        guard let d = player.sleepDeadline else { return 0 }
        let mins = Int(round(d.timeIntervalSinceNow / 60))
        return [15, 30, 60].min(by: { abs($0 - mins) < abs($1 - mins) }) ?? 30
    }
}

// MARK: - 播放页

// MARK: - 播放页（仿安卓版布局：集名 → 大封面 → 工具行 → 进度 → 15秒/上一集/播放/下一集/15秒）

struct PlayerView: View {
    @ObservedObject var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showEpisodes = false
    @State private var showSkip = false
    @State private var showRate = false
    @State private var showSleep = false
    @State private var showInfo = false

    var body: some View {
        NavigationView {
            VStack(spacing: 14) {
                // 集名（上）＋ 书名（下）
                VStack(spacing: 4) {
                    Text(player.currentEpisode?.title ?? "未在播放")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if let b = player.book {
                        Text(b.title).font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .padding(.top, 6)
                .padding(.horizontal)

                if let err = player.errorText {
                    Text(err).font(.caption).foregroundColor(.red).lineLimit(3).padding(.horizontal)
                }

                // 大封面
                AsyncImage(url: URL(string: player.book?.cover ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                } placeholder: {
                    ZStack {
                        Color(.secondarySystemBackground)
                        Image(systemName: "music.note").font(.system(size: 44)).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: 320, maxHeight: 320)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                Spacer(minLength: 0)

                // 工具行：定时 / 倍速 / 列表 / 片头片尾（原版那格「每日抽奖」已去掉）
                HStack(spacing: 0) {
                    Menu {
                        Button("不打开定时") { player.setSleep(minutes: nil) }
                        Button("15 分钟") { player.setSleep(minutes: 15) }
                        Button("30 分钟") { player.setSleep(minutes: 30) }
                        Button("60 分钟") { player.setSleep(minutes: 60) }
                        Button("听完本集停止") {
                            player.setSleep(minutes: nil)
                            player.stopAfterEpisode = true
                        }
                        Button("自定义…") { showSleep = true }
                    } label: { toolLabel("timer", sleepTitle) }

                    Button { withAnimation { showRate.toggle() } } label: { toolLabel("speedometer", rateLabel(player.rate)) }

                    Button { showEpisodes = true } label: { toolLabel("list.bullet", "选集 \(player.index + 1)/\(player.episodes.count)") }
                    Button { showSkip = true } label: { toolLabel("arrow.right.to.line", "片头片尾") }
                }
                .buttonStyle(.plain)
                .foregroundColor(.primary)
                .padding(.vertical, 4)

                // 倍速：直接在播放页滑，不再套菜单
                if showRate {
                    HStack(spacing: 10) {
                        Text("倍速").font(.caption2).foregroundColor(.secondary)
                        Slider(value: Binding(get: { Double(player.rate) },
                                              set: { player.setRate(Float(($0 * 100).rounded() / 100)) }),
                               in: 0.5...3.0, step: 0.05)
                        Text(rateLabel(player.rate)).font(.caption).monospacedDigit().frame(width: 54)
                    }
                    .padding(.horizontal)
                }

                // 进度
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { min(player.position, max(player.duration, 1)) },
                                          set: { player.seek(to: $0) }),
                           in: 0...max(player.duration, 1))
                    HStack {
                        Text(timeText(player.position)).font(.caption).monospacedDigit()
                        Spacer()
                        Text(timeText(player.duration)).font(.caption).monospacedDigit()
                    }
                }
                .padding(.horizontal)

                // 播放控制
                HStack(spacing: 30) {
                    Button { player.skip(-15) } label: {
                        Image(systemName: "gobackward.15").font(.system(size: 26))
                    }
                    Button { player.previous() } label: {
                        Image(systemName: "backward.end.fill").font(.system(size: 28))
                    }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 72))
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.end.fill").font(.system(size: 28))
                    }
                    Button { player.skip(15) } label: {
                        Image(systemName: "goforward.15").font(.system(size: 26))
                    }
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 8)
            .navigationTitle(player.book?.title ?? "正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("详情") { showInfo = true } }
            }
            .sheet(isPresented: $showEpisodes) { EpisodeListSheet() }
            .sheet(isPresented: $showSkip) { SkipSettingsSheet() }
            .sheet(isPresented: $showSleep) { SleepSheet() }
            .sheet(isPresented: $showInfo) { BookInfoSheet() }
        }
    }

    private func toolLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 21))
            Text(title).font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }

    private var sleepTitle: String {
        guard let d = player.sleepDeadline else { return "定时" }
        return "\(max(0, Int(d.timeIntervalSinceNow / 60)))分"
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}

// MARK: - 书籍详情（播放页右上角「详情」）

struct BookInfoSheet: View {
    @ObservedObject var player = PlayerEngine.shared
    @ObservedObject var cache = CacheManager.shared
    @ObservedObject var library = LibraryStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if let b = player.book {
                    Section {
                        HStack(alignment: .top, spacing: 12) {
                            AsyncImage(url: URL(string: b.cover)) { img in
                                img.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: { Color(.secondarySystemBackground) }
                            .frame(width: 88, height: 118)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 5) {
                                Text(b.title).font(.headline)
                                if !b.artist.isEmpty { Text("播音：\(b.artist)").font(.caption) }
                                if !b.author.isEmpty { Text("作者：\(b.author)").font(.caption) }
                                Text("共 \(player.episodes.count) 集").font(.caption).foregroundColor(.secondary)
                                Text("当前第 \(player.index + 1) 集").font(.caption2).foregroundColor(.secondary)
                            }
                        }
                    }

                    if !b.intro.isEmpty {
                        Section("简介") { Text(b.intro).font(.caption) }
                    }

                    Section("操作") {
                        Button {
                            library.toggleFavorite(b)
                        } label: {
                            Label(library.isFavorite(b) ? "取消收藏" : "收藏这本书",
                                  systemImage: library.isFavorite(b) ? "heart.fill" : "heart")
                        }
                    }
                } else {
                    Text("还没有在播放的书").foregroundColor(.secondary)
                }
            }
            .navigationTitle("书籍详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

// MARK: - 章节列表

struct EpisodeListSheet: View {
    @ObservedObject var player = PlayerEngine.shared
    @ObservedObject var cache = CacheManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var jumpText = ""

    var body: some View {
        NavigationView {
            List {
                // 快捷选集：直接输入集号跳
                Section {
                    HStack {
                        Text("跳到第")
                        TextField("集号", text: $jumpText)
                            .keyboardType(.numberPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                        Text("集")
                        Spacer()
                        Button("跳转") { jump() }
                            .disabled(Int(jumpText) == nil)
                    }
                    Text("当前第 \(player.index + 1) 集 / 共 \(player.episodes.count) 集")
                        .font(.caption2).foregroundColor(.secondary)
                }

                ForEach(player.episodes.indices, id: \.self) { i in
                    HStack {
                        Button {
                            if let book = player.book {
                                player.play(book: book, episodes: player.episodes, startAt: i)
                            }
                            dismiss()
                        } label: {
                            HStack {
                                Text("\(i + 1). " + (player.episodes[i].title.isEmpty ? "第 \(i + 1) 集" : player.episodes[i].title))
                                    .font(.subheadline).lineLimit(1)
                                Spacer()
                                if i == player.index {
                                    Image(systemName: "speaker.wave.2.fill").foregroundColor(.orange)
                                }
                            }
                        }
                        .buttonStyle(.plain)

                        // 缓存这一集
                        if cache.isCached(player.episodes[i].url) {
                            Image(systemName: "arrow.down.circle.fill").foregroundColor(.green)
                        } else if cache.isDownloading(player.episodes[i].url) {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Button {
                                guard let book = player.book,
                                      let src = SourceStore.shared.all.first(where: { $0.id == book.sourceId }) else { return }
                                let ep = player.episodes[i]
                                Task { await CacheManager.shared.cache(episode: ep, source: src) }
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("选集（\(player.episodes.count) 集）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func jump() {
        guard let n = Int(jumpText), n >= 1, n <= player.episodes.count, let book = player.book else { return }
        player.play(book: book, episodes: player.episodes, startAt: n - 1)
        dismiss()
    }
}

// MARK: - 倍速（自定义）

struct RateSheet: View {
    @ObservedObject var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var value: Double = 1.0

    var body: some View {
        NavigationView {
            Form {
                Section("拖动设置任意倍速（0.50x – 3.00x）") {
                    HStack {
                        Text("当前倍速")
                        Spacer()
                        Text(String(format: "%.2fx", value)).monospacedDigit().foregroundColor(.orange)
                    }
                    Slider(value: Binding(get: { value },
                                          set: { value = $0; player.setRate(Float($0)) }),
                           in: 0.5...3.0, step: 0.05)
                    HStack(spacing: 12) {
                        Button("-0.05") { bump(-0.05) }
                        Button("1.0x") { set(1.0) }
                        Button("+0.05") { bump(0.05) }
                    }
                    .buttonStyle(.bordered)
                }
                Section("常用") {
                    ForEach(rateOptions) { opt in
                        Button {
                            set(Double(opt.value))
                        } label: {
                            HStack {
                                Text(opt.label)
                                Spacer()
                                if abs(Double(opt.value) - value) < 0.001 {
                                    Image(systemName: "checkmark").foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("倍速")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { player.setRate(Float(value)); dismiss() }
                }
            }
            .onAppear { value = Double(player.rate) }
        }
    }

    private func bump(_ d: Double) { set(value + d) }

    private func set(_ v: Double) {
        value = min(3.0, max(0.5, (v * 100).rounded() / 100))
        player.setRate(Float(value))
    }
}

// MARK: - 定时关闭（自定义分钟）

struct SleepSheet: View {
    @ObservedObject var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 30

    var body: some View {
        NavigationView {
            Form {
                Section("自定义") {
                    Stepper("\(minutes) 分钟后停止", value: $minutes, in: 5...300, step: 5)
                    Button("开始计时") {
                        player.setSleep(minutes: minutes)
                        dismiss()
                    }
                    if player.sleepDeadline != nil {
                        Button("取消定时", role: .destructive) {
                            player.setSleep(minutes: nil)
                            dismiss()
                        }
                    }
                }
                Section("常用") {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                        Button("\(m) 分钟") {
                            player.setSleep(minutes: m)
                            dismiss()
                        }
                    }
                }
                Section {
                    Toggle("听完本集后停止", isOn: Binding(
                        get: { player.stopAfterEpisode },
                        set: { player.stopAfterEpisode = $0 }))
                    Text("打开后：当前这集播完就暂停，不会自动续下一集（适合睡前听一集）。")
                        .font(.caption).foregroundColor(.secondary)
                }
                Section {
                    Text("到点会自动暂停播放（App 在后台也会生效）。").font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("定时关闭")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }
}

// MARK: - 片头片尾设置

struct SkipSettingsSheet: View {
    @ObservedObject var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("自动跳过") {
                    Picker("片头", selection: Binding(get: { Int(player.skipIntro) },
                                                     set: { player.skipIntro = Double($0) })) {
                        Text("不跳过").tag(0); Text("5 秒").tag(5); Text("10 秒").tag(10)
                        Text("15 秒").tag(15); Text("30 秒").tag(30); Text("45 秒").tag(45); Text("60 秒").tag(60)
                    }
                    Picker("片尾", selection: Binding(get: { Int(player.skipOutro) },
                                                     set: { player.skipOutro = Double($0) })) {
                        Text("不跳过").tag(0); Text("5 秒").tag(5); Text("10 秒").tag(10)
                        Text("15 秒").tag(15); Text("30 秒").tag(30); Text("45 秒").tag(45); Text("60 秒").tag(60)
                    }
                }
                Section {
                    Text("每集开始时会自动跳过设定的「片头」秒数；播放到离结尾还剩「片尾」秒数时，自动进入下一集。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("片头片尾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - 倍速选项（播放页与设置共用）

struct RateOption: Identifiable {
    var id: Float { value }
    let value: Float
    let label: String
}

let rateOptions: [RateOption] = [
    RateOption(value: 0.75, label: "0.75x"),
    RateOption(value: 1.0, label: "1.0x"),
    RateOption(value: 1.25, label: "1.25x"),
    RateOption(value: 1.5, label: "1.5x"),
    RateOption(value: 2.0, label: "2.0x")
]

/// 倍速显示文本（支持任意自定义值）
func rateLabel(_ r: Float) -> String {
    if let hit = rateOptions.first(where: { abs($0.value - r) < 0.01 }) { return hit.label }
    return String(format: "%.2fx", r)
}

// MARK: - 诊断页（源测试 + 订阅链接测试 + 复制报告）

struct DiagnosticsView: View {
    @ObservedObject var store = SourceStore.shared
    @ObservedObject var settings = SourceSettings.shared
    @ObservedObject var cache = CacheManager.shared
    @StateObject private var diag = Diagnostics()
    @Environment(\.dismiss) private var dismiss
    @State private var linkURL = defaultSubscriptionURL
    @State private var copied = false

    var body: some View {
        NavigationView {
            List {
                Section {
                    infoRow("App 版本", "\(appVersion) (\(buildNumber))")
                    infoRow("系统", "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    infoRow("机型", UIDevice.current.model)
                    infoRow("已启用源", "\(settings.enabledSources.count)/\(store.all.count)")
                    infoRow("缓存占用", cache.sizeText())
                } header: { Text("环境") }

                Section {
                    Button {
                        Task { await diag.runAll(sources: settings.enabledSources) }
                    } label: {
                        if diag.running {
                            HStack { ProgressView(); Text("测试中…") }
                        } else {
                            Text("一键测试所有源（搜索「三体」）")
                        }
                    }
                    .disabled(diag.running)

                    Button {
                        Task { await diag.runDeep(sources: settings.enabledSources) }
                    } label: {
                        Text("深度测试（搜索 → 章节 → 音频试听）")
                    }
                    .disabled(diag.running)
                    Text("深度测试会把每个源的第一本书走完整链路，并真拉 1KB 音频确认能播（不真的出声）；每个源几秒，慢一些。")
                        .font(.caption2).foregroundColor(.secondary)

                    ForEach(diag.rows) { r in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(r.ok == nil ? "⏳" : (r.ok! ? "✅" : "❌"))
                                Text(r.name).font(.subheadline)
                                Spacer()
                                Text("\(r.ms)ms").font(.caption2).foregroundColor(.secondary)
                            }
                            Text(r.detail).font(.caption2).foregroundColor(.secondary).lineLimit(3)
                        }
                    }
                } header: { Text("源测试") }

                Section {
                    TextField("订阅地址", text: $linkURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .font(.caption)
                    Button("测试这个订阅链接") { Task { await diag.testSubscription(linkURL) } }
                    if let s = diag.linkResult {
                        Text(s).font(.caption2)
                    }
                } header: { Text("订阅链接") }

                Section {
                    Button(copied ? "已复制到剪贴板 ✓" : "复制诊断报告") {
                        UIPasteboard.general.string = diag.report(settings: settings, cache: cache)
                        copied = true
                    }
                    .disabled(diag.rows.isEmpty)
                }
            }
            .navigationTitle("诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }
}
