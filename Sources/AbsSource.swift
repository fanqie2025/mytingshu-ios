import Foundation

// MARK: - Audiobookshelf（连你自己的 ABS 服务器）
//
// 这不是"抓站源"，而是连你自建服务器：在 设置 → 源管理 → Audiobookshelf 里填
//   服务器地址（如 http://192.168.10.111:13378）
//   API Token（ABS 里 设置 → 用户 → API Token）
// 然后用 /api/libraries、/api/libraries/{id}/items、/api/items/{id} 取书与音频流。

/// ABS 配置（存 UserDefaults）
/// 注意：**不能**标 @MainActor —— BookSource 的方法是在后台跑的，
/// 标了就变成「主线程隔离属性不能从非隔离上下文引用」编译错误。
final class AbsConfig: ObservableObject {
    static let shared = AbsConfig()

    /// 登录方式："key" = 用 API Key；"password" = 用用户名 + 密码（自动换 token）
    @Published var mode: String {
        didSet { UserDefaults.standard.set(mode, forKey: "abs_mode_v1") }
    }
    @Published var server: String {
        didSet { UserDefaults.standard.set(server, forKey: "abs_server_v1") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "abs_token_v1") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "abs_user_v1") }
    }
    @Published var password: String {
        didSet { UserDefaults.standard.set(password, forKey: "abs_pass_v1") }
    }

    private init() {
        mode = UserDefaults.standard.string(forKey: "abs_mode_v1") ?? "key"
        server = UserDefaults.standard.string(forKey: "abs_server_v1") ?? ""
        token = UserDefaults.standard.string(forKey: "abs_token_v1") ?? ""
        username = UserDefaults.standard.string(forKey: "abs_user_v1") ?? ""
        password = UserDefaults.standard.string(forKey: "abs_pass_v1") ?? ""
    }

    /// 去掉末尾斜杠、补上 http://
    var base: String {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.hasPrefix("http") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 拿到能用的 token：用户名密码模式就先登录换一个
    func ensureToken() async throws -> String {
        let b = base
        guard !b.isEmpty else { throw SourceError.message("还没配置 ABS 服务器地址") }
        if mode == "password" {
            if !username.isEmpty, !password.isEmpty {
                let t = try await AbsLogin.login(server: b, username: username, password: password)
                if !t.isEmpty {
                    token = t
                    return t
                }
            }
            if !token.isEmpty { return token }
            throw SourceError.message("请填用户名和密码（或切到 API Key）")
        }
        guard !token.isEmpty else { throw SourceError.message("请填 API Key") }
        return token
    }
}

/// ABS 登录：用户名 + 密码 → token
enum AbsLogin {
    static func login(server: String, username: String, password: String) async throws -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let body = #"{"username":"\#(esc(username))","password":"\#(esc(password))"}"#
        let text = try await HTTPClient.postJSON(server + "/api/login", json: body,
                                                referer: server, mobile: false)
        guard let d = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw SourceError.parse("登录返回不是 JSON")
        }
        if let u = obj["user"] as? [String: Any], let t = u["token"] as? String, !t.isEmpty { return t }
        if let t = obj["token"] as? String, !t.isEmpty { return t }
        throw SourceError.message("登录失败：用户名或密码不对")
    }
}

final class AbsSource: BookSource {
    static let sourceId = "ab50000000000000000000000000abcd"
    let id = AbsSource.sourceId
    let name = "Audiobookshelf"
    let desc = "连你自己的 Audiobookshelf 服务器（设置 → 源管理 → 配置里填地址和 Token）。"

    var host: String { AbsConfig.shared.base.isEmpty ? "about:blank" : AbsConfig.shared.base }

    private func api(_ path: String) async throws -> [String: Any] {
        let base = AbsConfig.shared.base
        guard !base.isEmpty else { throw SourceError.message("还没配置 ABS 服务器地址") }
        // 用户名密码模式会在这里自动登录换 token
        let token = try await AbsConfig.shared.ensureToken()
        let url = "\(base)\(path)\(path.contains("?") ? "&" : "?")token=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)"
        let text = try await HTTPClient.text(url, referer: base, mobile: false)
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("ABS 返回不是 JSON（地址或 Token 可能不对）")
        }
        if let err = obj["error"] as? String { throw SourceError.message("ABS：\(err)") }
        return obj
    }

    // MARK: 库 / 书

    private func libraries() async throws -> [(String, String)] {
        let obj = try await api("/api/libraries")
        let arr = (obj["libraries"] as? [[String: Any]]) ?? []
        return arr.compactMap { lib in
            guard let id = lib["id"] as? String, let name = lib["name"] as? String else { return nil }
            return (id, name)
        }
    }

    private func book(from item: [String: Any]) -> Book? {
        guard let itemId = item["id"] as? String else { return nil }
        let media = (item["media"] as? [String: Any]) ?? [:]
        let meta = (media["metadata"] as? [String: Any]) ?? [:]
        let title = anyString(meta["title"])
        guard !title.isEmpty else { return nil }
        let base = AbsConfig.shared.base
        let token = AbsConfig.shared.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return Book(sourceId: id,
                    title: title,
                    author: anyString(meta["authorName"]),
                    artist: anyString(meta["narratorName"]),
                    cover: "\(base)/api/items/\(itemId)/cover?token=\(token)",
                    bookURL: "\(base)/api/items/\(itemId)",
                    intro: cleanText(meta["description"]))
    }

    func search(keyword: String, page: Int) async throws -> [Book] {
        let libs = try await libraries()
        var out: [Book] = []
        var seen = Set<String>()
        let kw = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        for (libId, _) in libs {
            // 新版 ABS 用 /search，旧版退回 items?search=
            var items: [[String: Any]] = []
            if let obj = try? await api("/api/libraries/\(libId)/search?q=\(kw)&limit=40") {
                for key in ["book", "items", "authors", "series"] {
                    if let arr = obj[key] as? [[String: Any]] {
                        for it in arr {
                            if let lib = it["libraryItem"] as? [String: Any] { items.append(lib) } else { items.append(it) }
                        }
                    }
                }
            }
            if items.isEmpty, let obj = try? await api("/api/libraries/\(libId)/items?search=\(kw)&limit=40") {
                items = (obj["results"] as? [[String: Any]]) ?? []
            }
            for it in items {
                guard let b = book(from: it), !seen.contains(b.bookURL) else { continue }
                seen.insert(b.bookURL)
                out.append(b)
            }
        }
        return out
    }

    func menus() async throws -> [CategoryMenu] {
        let libs = try await libraries()
        guard !libs.isEmpty else { return [] }
        let cats = libs.map { SourceCategory(title: $0.1, url: "\(AbsConfig.shared.base)/api/libraries/\($0.0)") }
        return [CategoryMenu(title: "书库", categories: cats)]
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        guard let libId = category.url.split(separator: "/").last.map(String.init) else { return [] }
        let obj = try await api("/api/libraries/\(libId)/items?limit=50&page=\(max(0, page - 1))&sort=addedAt&desc=1")
        let items = (obj["results"] as? [[String: Any]]) ?? []
        return items.compactMap { book(from: $0) }
    }

    // MARK: 详情 / 章节（ABS 的音频文件即"集"）

    func detail(for book: Book) async throws -> BookDetail {
        guard let itemId = book.bookURL.split(separator: "/").last.map(String.init) else {
            throw SourceError.parse("书籍地址异常")
        }
        let obj = try await api("/api/items/\(itemId)?expanded=1")
        var out = BookDetail()
        let media = (obj["media"] as? [String: Any]) ?? [:]
        let meta = (media["metadata"] as? [String: Any]) ?? [:]
        out.intro = cleanText(meta["description"])
        out.author = anyString(meta["authorName"])
        out.artist = anyString(meta["narratorName"])
        out.cover = book.cover

        let files = (media["audioFiles"] as? [[String: Any]]) ?? []
        let chapters = (media["chapters"] as? [[String: Any]]) ?? []
        let base = AbsConfig.shared.base
        let token = AbsConfig.shared.token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        var episodes: [Episode] = []
        for (i, f) in files.enumerated() {
            let idx = (f["index"] as? Int) ?? i
            let fmeta = (f["metadata"] as? [String: Any]) ?? [:]
            var title = anyString(fmeta["filename"])
            if title.isEmpty { title = "第 \(i + 1) 段" }
            episodes.append(Episode(title: title, url: "\(base)/api/items/\(itemId)/file/\(idx)?token=\(token)"))
        }
        // 只有一个音频文件但有章节时，按章节切（用 start 偏移做标记，播放仍在同一文件）
        if episodes.count == 1, chapters.count > 1 {
            episodes = chapters.enumerated().map { (i, c) in
                let t = anyString(c["title"]).isEmpty ? "第 \(i + 1) 章" : anyString(c["title"])
                return Episode(title: t, url: episodes[0].url)
            }
        }
        if episodes.isEmpty { throw SourceError.parse("这本在 ABS 里没有音频文件") }
        out.episodes = episodes
        return out
    }

    func audioURL(for episode: Episode) async throws -> URL {
        // episode.url 已经带 token，可直接播
        guard let u = URL(string: episode.url) else { throw SourceError.badURL(episode.url) }
        return u
    }

    /// 测试连接：返回库数量
    func testConnection() async throws -> String {
        let libs = try await libraries()
        return "连接成功，共 \(libs.count) 个书库：" + libs.map { $0.1 }.joined(separator: "、")
    }
}
