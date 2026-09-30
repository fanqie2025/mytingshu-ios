import SwiftUI
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

    private func runSearch() async {
        guard !keyword.isEmpty, !searching else { return }
        searching = true
        results = []; errors = []
        let kw = keyword
        let sources = settings.enabledSources.filter { $0.searchable }
        await withTaskGroup(of: (any BookSource, Result<[Book], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do { return (s, .success(try await s.search(keyword: kw, page: 1))) }
                    catch { return (s, .failure(error)) }
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
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
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
                    Picker("倍速", selection: Binding(get: { Double(player.rate) }, set: { player.setRate(Float($0)) })) {
                        Text("0.75x").tag(0.75); Text("1.0x").tag(1.0)
                        Text("1.25x").tag(1.25); Text("1.5x").tag(1.5); Text("2.0x").tag(2.0)
                    }
                    Picker("定时关闭", selection: Binding(
                        get: { sleepTag },
                        set: { player.setSleep(minutes: $0 == 0 ? nil : $0) })) {
                        Text("关闭").tag(0); Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30); Text("60 分钟").tag(60)
                    }
                }

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text("0.1.0").foregroundColor(.secondary) }
                    HStack { Text("源数量"); Spacer(); Text("\(settings.enabledSources.count)/\(store.all.count)").foregroundColor(.secondary) }
                    Text("本 App 只做播放器，内容来自各听书站；音频版权归原站所有。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showImport) { importSheet }
        }
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

struct PlayerView: View {
    @ObservedObject var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                Spacer(minLength: 8)
                AsyncImage(url: URL(string: player.book?.cover ?? "")) { img in
                    img.resizable().aspectRatio(contentMode: .fit)
                } placeholder: { Color(.secondarySystemBackground) }
                .frame(maxWidth: 300, maxHeight: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                VStack(spacing: 4) {
                    Text(player.book?.title ?? "").font(.headline).lineLimit(1)
                    Text(player.currentEpisode?.title ?? "").font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                }

                if let err = player.errorText { Text(err).font(.caption).foregroundColor(.red) }

                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }),
                       in: 0...max(player.duration, 1))
                HStack {
                    Text(timeText(player.position)).font(.caption2).monospacedDigit()
                    Spacer()
                    Text(timeText(player.duration)).font(.caption2).monospacedDigit()
                }

                HStack(spacing: 34) {
                    Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title) }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 64))
                    }
                    Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title) }
                }
                .buttonStyle(.plain)

                HStack(spacing: 24) {
                    Picker("倍速", selection: Binding(get: { Double(player.rate) }, set: { player.setRate(Float($0)) })) {
                        Text("0.75x").tag(0.75); Text("1.0x").tag(1.0)
                        Text("1.25x").tag(1.25); Text("1.5x").tag(1.5); Text("2.0x").tag(2.0)
                    }
                    .pickerStyle(.menu)
                    if let d = player.sleepDeadline {
                        Text("定时 \(max(0, Int(d.timeIntervalSinceNow / 60))) 分")
                            .font(.caption).foregroundColor(.orange)
                            .onTapGesture { player.setSleep(minutes: nil) }
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("收起") { dismiss() } } }
        }
    }

    private func timeText(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "00:00" }
        let t = Int(s)
        return String(format: "%02d:%02d", t / 60, t % 60)
    }
}
