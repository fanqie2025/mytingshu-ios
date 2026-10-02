import SwiftUI
import UIKit
import WebKit

// MARK: - 迷你播放条

/// 迷你播放条（唔语形态，截图 01/05/06）：**非全宽胶囊**，`Theme.surface` 底，
/// 内含 40pt 圆形封面 + 1 行标题 + **蓝色播放三角**（不是圆形按钮）；
/// 宽随标题变化、左对齐。点胶囊开播放页，点三角播放/暂停。
/// 放在每个页签内容的底部（不贴在 TabView 上），这样不会盖住底部 dock 栏。
struct MiniPlayerBar: View {
    @ObservedObject var player = PlayerEngine.shared
    @State private var showFull = false

    var body: some View {
        if let book = player.book, let ep = player.currentEpisode {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    CoverImage(url: book.cover, side: 40, radius: Theme.Radius.coverMini)

                    Text(ep.title.isEmpty ? book.title : ep.title)
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text1)
                        .lineLimit(1)

                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(Theme.accent)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 6)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.surface))
                .contentShape(Capsule())
                .onTapGesture { showFull = true }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, Theme.Space.row)
            .fullScreenCover(isPresented: $showFull) { PlayerScreen() }
        }
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
    @Environment(\.dismiss) private var dismiss
    @State private var showImport = false
    @State private var showDiag = false
    @State private var showAbs = false
    @State private var importText = ""
    @State private var importURL = ""
    @State private var importMsg = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            List {
                Section("源管理") {
                    ForEach(store.all, id: \.id) { src in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(src.name)
                                Text(src.host).font(.caption2).foregroundColor(.secondary)
                                if !src.desc.isEmpty {
                                    Text(src.desc).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            if src.id == AbsSource.sourceId {
                                Button("配置") { showAbs = true }
                                    .font(.footnote)
                            }
                            Toggle("", isOn: Binding(
                                get: { settings.enabled.contains(src.id) },
                                set: { on in
                                    if on { settings.enabled.insert(src.id) } else { settings.enabled.remove(src.id) }
                                }))
                            .labelsHidden()
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

                Section("关于") {
                    HStack { Text("版本"); Spacer(); Text(Bundle.main.appVersionText).foregroundColor(.secondary) }
                    HStack { Text("源数量"); Spacer(); Text("\(settings.enabledSources.count)/\(store.all.count)").foregroundColor(.secondary) }
                    Button("诊断 / 源测试") { showDiag = true }
                    Text("本 App 只做播放器，内容来自各听书站；音频版权归原站所有。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $showImport) { importSheet }
            .sheet(isPresented: $showDiag) { DiagnosticsView() }
            .sheet(isPresented: $showAbs) { AbsConfigSheet() }
        }
    }

    private var importSheet: some View {
        NavigationView {
            Form {
                Section("粘贴订阅地址（推荐）") {
                    TextField("https://…/sources.json", text: $importURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .onChange(of: importURL) { newValue in
                            // 隐藏快捷入口：地址框里输入 666 → 自动换成内置的官方订阅地址
                            if newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                == SourceStore.builtinSubscriptionKeyword {
                                importURL = SourceStore.officialSubscriptionURL
                            }
                        }
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
            // 隐藏快捷入口兜底：万一 666 没被 onChange 替换掉（例如从剪贴板整段粘贴后直接点导入），这里再解析一次
            let typed = importURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = (typed == SourceStore.builtinSubscriptionKeyword)
                ? SourceStore.officialSubscriptionURL
                : typed
            let names = try await store.importURL(target)
            settings.enableNewSources()
            importMsg = "✅ 导入成功：\(names.joined(separator: "、"))"
            importURL = ""
        } catch {
            importMsg = "❌ \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
        }
        busy = false
    }
}

// MARK: - 播放页

// MARK: - 书籍详情（播放页右上角「详情」）

struct BookInfoSheet: View {
    @ObservedObject var player = PlayerEngine.shared
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
    @Environment(\.dismiss) private var dismiss
    @State private var rangeIndex: Int? = nil

    /// 每 20 集一组（和原版一致）
    private let chunk = 20

    private var chunks: [[Int]] {
        stride(from: 0, to: player.episodes.count, by: chunk).map { start in
            Array(start..<min(start + chunk, player.episodes.count))
        }
    }

    private var visible: [Int] {
        if let r = rangeIndex, r >= 0, r < chunks.count { return chunks[r] }
        return Array(player.episodes.indices)
    }

    var body: some View {
        NavigationView {
            List {
                // 注：这里曾有「缓存接下来 10 集」批量下载与「删除本书缓存」，已按用户要求移除 ——
                // 连续拉多个音频最容易招源站风控。选集列表里每行的 ↓（单集缓存）保留。

                // 选集：每 20 集一个格子，点一下只看这一段
                if chunks.count > 1 {
                    Section {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                                  spacing: 8) {
                            ForEach(chunks.indices, id: \.self) { ci in
                                let c = chunks[ci]
                                let on = rangeIndex == ci
                                Button {
                                    rangeIndex = on ? nil : ci
                                } label: {
                                    Text("\(c[c.startIndex] + 1)~\(c[c.endIndex - 1] + 1)")
                                        .font(.callout)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .background(on ? Color.orange.opacity(0.85) : Color(.secondarySystemBackground))
                                        .foregroundColor(on ? .white : .primary)
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                        HStack {
                            Text("当前第 \(player.index + 1) 集 / 共 \(player.episodes.count) 集")
                                .font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            if rangeIndex != nil {
                                Button("显示全部") { rangeIndex = nil }.font(.caption2)
                            }
                        }
                    } header: {
                        Text("选集（每 \(chunk) 集一组）")
                    }
                }

                ForEach(visible, id: \.self) { i in
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
                        // 注：这里曾有单集「缓存这一集」按钮，已按用户要求移除（连同批量与自动缓存）
                    }
                }
            }
            .navigationTitle("选集（共 \(player.episodes.count) 集）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } } }
            .onAppear {
                // 默认定位到正在播放的那一组
                if let ci = chunks.firstIndex(where: { $0.contains(player.index) }) {
                    rangeIndex = ci
                }
            }
        }
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
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("跳过片头片尾").font(.largeTitle.bold()).foregroundColor(.blue)
                    Text("设置后只对本专辑有效").font(.subheadline).foregroundColor(.secondary)
                }
                .padding(.top, 10)

                stepRow(title: "跳过片头", value: player.skipIntro) { player.skipIntro = $0 }
                stepRow(title: "跳过片尾", value: player.skipOutro) { player.skipOutro = $0 }

                Text("每集开始自动跳过「片头」秒数；播到离结尾还剩「片尾」秒数时自动下一集。")
                    .font(.caption).foregroundColor(.secondary)

                Spacer()

                Button { dismiss() } label: {
                    Text("关闭").font(.title3).frame(maxWidth: .infinity)
                }
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 22)
            .navigationBarHidden(true)
            .onDisappear { player.saveSkipForCurrentBook() }
        }
    }

    /// 「跳过片头 N 秒」＋ 左 −1秒 / 滑块 / 右 +1秒
    private func stepRow(title: String, value: Double, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) \(Int(value)) 秒").font(.title3.bold())
            HStack(spacing: 8) {
                Button { onChange(max(0, value - 1)) } label: {
                    VStack(spacing: 0) {
                        Image(systemName: "minus").font(.caption)
                        Text("1秒").font(.caption2)
                    }
                    .frame(width: 34)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)

                Slider(value: Binding(get: { value },
                                      set: { onChange($0.rounded()) }),
                       in: 0...120, step: 1)

                Button { onChange(min(120, value + 1)) } label: {
                    VStack(spacing: 0) {
                        Image(systemName: "plus").font(.caption)
                        Text("1秒").font(.caption2)
                    }
                    .frame(width: 34)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
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
    // 倍速统一保留两位小数（1.00x / 1.25x / 1.50x …）
    String(format: "%.2fx", r)
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

// MARK: - Audiobookshelf 配置

struct AbsConfigSheet: View {
    @ObservedObject var cfg = AbsConfig.shared
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var mode = "key"
    @State private var token = ""
    @State private var username = ""
    @State private var password = ""
    @State private var result = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section("服务器地址") {
                    TextField("http://192.168.10.111:13378", text: $server)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                }

                Section("登录方式（可随时切换）") {
                    Picker("", selection: $mode) {
                        Text("API Key").tag("key")
                        Text("用户名 + 密码").tag("password")
                    }
                    .pickerStyle(.segmented)
                }

                if mode == "key" {
                    Section("API Key") {
                        TextField("ABS 里 设置 → 用户 → API Token", text: $token)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                    }
                } else {
                    Section("账号") {
                        TextField("用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        SecureField("密码", text: $password)
                    }
                    Text("保存时用账号登录一次，换成本机保存的 token；以后一直用它。")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section {
                    Button { Task { await test() } } label: {
                        if busy { HStack { ProgressView(); Text("测试中…") } } else { Text("保存并测试连接") }
                    }
                    if !result.isEmpty {
                        Text(result).font(.caption)
                    }
                }

                Section {
                    Text("填好后，你的 ABS 书库会作为一个源出现在「书源」和「搜索」里；音频直接从你的服务器播放，不经过任何第三方。")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("Audiobookshelf")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() } }
            }
            .onAppear {
                server = cfg.server
                mode = cfg.mode
                token = cfg.token
                username = cfg.username
                password = cfg.password
            }
        }
    }

    private func save() {
        cfg.server = server.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.mode = mode
        cfg.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.password = password
    }

    private func test() async {
        save()
        busy = true
        do {
            result = "✅ " + (try await AbsSource().testConnection())
        } catch {
            result = "❌ " + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        busy = false
    }
}
