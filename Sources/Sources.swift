import Foundation
import CryptoKit

// MARK: - 书音FM（m.mekui.com）JSON 接口

/// 接口结构与安卓端 m1ngzer 源一致：ecmsapi + MD5 token
final class MekuiSource: BookSource {
    let id = "e16485b62deccfc7a1b2c3d4e5f60718"
    let name = "书音FM"
    let host = "https://m.mekui.com"
    let desc = "有声小说/评书/广播剧，接口稳定，无需验证。"

    private let api = "https://m.mekui.com/ecmsapi/index.php"
    private let tokenKey = "056a308c515e16b2fe5a5c631319339cbc60a8ee0e03d016"

    private func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func json(_ params: [String: String]) async throws -> [String: Any] {
        var comps = URLComponents(string: api)!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, http) = try await HTTPClient.data(comps.url!.absoluteString, referer: host + "/")
        guard http.statusCode == 200 else { throw SourceError.http(http.statusCode, comps.url!.absoluteString) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("返回不是 JSON")
        }
        return obj
    }

    private func book(from item: [String: Any]) -> Book {
        let bid = anyString(item["id"])
        return Book(sourceId: id,
                    title: anyString(item["title"]),
                    author: anyString(item["author"] ?? item["writer"]),
                    artist: anyString(item["player"] ?? item["actor"]),
                    cover: anyString(item["titlepic"] ?? item["pic"]),
                    bookURL: "\(host)/book/\(bid)",
                    intro: cleanText(item["intro"] ?? item["content"]))
    }

    func search(keyword: String, page: Int) async throws -> [Book] {
        let root = try await json(["mod": "movie", "act": "search", "keyword": keyword,
                                   "page": "\(page)", "pagesize": "20"])
        let list = ((root["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return list.map(book(from:))
    }

    func menus() async throws -> [CategoryMenu] {
        let root = try await json(["mod": "column", "act": "navigation", "classid": "0"])
        let list = (root["list"] as? [[String: Any]]) ?? []
        let cats = list.compactMap { item -> SourceCategory? in
            guard let cid = item["id"] ?? item["classid"], let name = item["classname"] as? String else { return nil }
            return SourceCategory(title: name, url: "\(host)/list/\(cid)")
        }
        return cats.isEmpty ? [] : [CategoryMenu(title: "分类", categories: cats)]
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        let cid = category.url.split(separator: "/").last.map(String.init) ?? "1"
        let root = try await json(["mod": "movie", "act": "list", "classid": cid,
                                   "page": "\(page)", "pagesize": "20"])
        let list = ((root["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
        return list.map(book(from:))
    }

    func detail(for book: Book) async throws -> BookDetail {
        let bid = book.bookURL.split(separator: "/").last.map(String.init) ?? ""
        let detailRoot = try await json(["mod": "movie", "act": "detail", "id": bid])
        let d = ((detailRoot["data"] as? [String: Any])?["detail"] as? [String: Any]) ?? [:]

        let chapterRoot = try await json(["mod": "movie", "act": "movielist", "id": bid,
                                          "page": "1", "pagesize": "1000"])
        let chapters = ((chapterRoot["data"] as? [String: Any])?["moielist"] as? [[String: Any]]) ?? []
        let episodes = chapters.map { c -> Episode in
            let cid = anyString(c["id"])
            return Episode(title: anyString(c["title"]),
                           url: "\(host)/play/\(bid)/\(cid)")
        }
        var out = BookDetail()
        out.episodes = episodes
        out.intro = cleanText(d["intro"] ?? d["content"])
        out.artist = anyString(d["player"] ?? d["actor"])
        out.author = anyString(d["author"] ?? d["writer"])
        let pic = anyString(d["titlepic"] ?? d["pic"])
        out.cover = pic.isEmpty ? book.cover : pic
        return out
    }

    func audioURL(for episode: Episode) async throws -> URL {
        // url 形如 https://m.mekui.com/play/<bookId>/<chapterId>
        let parts = episode.url.split(separator: "/")
        guard parts.count >= 2 else { throw SourceError.parse("章节链接异常") }
        let chapterId = String(parts[parts.count - 1])
        let bookId = String(parts[parts.count - 2])
        let ts = Int(Date().timeIntervalSince1970)
        let raw = "act=wapseries&id=\(bookId)&mod=movie&movieId=\(chapterId)&t=\(ts)"
        let token = md5(raw + "&token=" + tokenKey)
        let (data, _) = try await HTTPClient.data(api + "?" + raw + "&token=" + token, referer: host + "/")
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let series = ((obj["data"] as? [String: Any])?["SeriesUrl"] as? String), !series.isEmpty else {
            throw SourceError.parse("未取到 SeriesUrl")
        }
        let final = await HTTPClient.resolveFinalURL(series, referer: host + "/")
        guard let url = URL(string: final) else { throw SourceError.badURL(final) }
        return url
    }
}

// MARK: - 22听书（22ting.com，一夜幻听网）

/// 与安卓端 Ting22 对齐：搜索需要过一次图片验证码，分类/章节/播放不需要。
final class Ting22Source: BookSource {
    let id = "22a11c0de5f60718293a4b5c6d7e8f90"
    let name = "22听书"
    let host = "https://22ting.com"
    let desc = "一夜幻听网。搜索需过一次图片验证码；分类/章节/播放无需验证。站点限制搜索 6 秒一次。"
    let needsVerification = true

    private let base = "https://22ting.com/"

    private func get(_ path: String) async throws -> String {
        try await HTTPClient.text(base + path, referer: base)
    }

    // MARK: 解析列表（搜索页与分类页结构一致）

    private func parseBooks(_ html: String) -> [Book] {
        let blocks = html.allMatches(#"<li[^>]*class="col[^"]*"[^>]*>([\s\S]*?)</li>"#)
        var books: [Book] = []
        for block in blocks {
            guard let titleTag = block.firstMatch(#"(<a[^>]*class="f-bold"[^>]*>[\s\S]*?</a>)"#) else { continue }
            let href = titleTag.firstMatch(#"href="([^"]+)""#) ?? ""
            let title = titleTag.strippedTags.htmlDecoded
            if title.isEmpty || href.isEmpty { continue }
            let cover = block.firstMatch(#"<img[^>]+src="([^"]+)""#) ?? ""
            let intro = block.firstMatch(#"<p class="f-gray[^"]*"[^>]*>([\s\S]*?)</p>"#)?.strippedTags.htmlDecoded ?? ""
            var artist = block.firstMatch(#"<span class="fr[^"]*"[^>]*>([\s\S]*?)</span>"#)?.strippedTags.htmlDecoded ?? ""
            var author = artist
            if let m = intro.firstMatch(#"作者：(.*?)，由(.*?)播音"#, group: 1) { author = m }
            if let m = intro.firstMatch(#"作者：(.*?)，由(.*?)播音"#, group: 2) { artist = m }
            books.append(Book(sourceId: id, title: title, author: author, artist: artist,
                              cover: cover.absoluteURL(base: base), bookURL: href.absoluteURL(base: base),
                              intro: intro))
        }
        return books
    }

    func search(keyword: String, page: Int) async throws -> [Book] {
        let kw = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        let html = try await get("search.php?page=\(page)&searchword=\(kw)&searchtype=")
        if html.contains("系统安全验证") { throw SourceError.needVerification }
        if html.contains("搜索限制") || html.contains("提示信息") { return [] } // 6 秒限流
        return parseBooks(html)
    }

    func menus() async throws -> [CategoryMenu] {
        let cats: [(String, String)] = [
            ("玄幻", "221"), ("言情", "222"), ("都市", "223"), ("恐怖", "224"),
            ("惊悚", "225"), ("推理", "226"), ("武侠", "227"), ("历史", "228"),
            ("军事", "229"), ("穿越", "2210"), ("科幻", "2211"), ("网游", "2212"),
            ("评书", "2213"), ("戏曲", "2214"), ("笑话", "2215"), ("儿童", "2216"),
            ("财经", "2217"), ("广播", "2218"), ("诗歌", "2219"), ("文学", "2220"),
            ("粤语", "2221"), ("经典", "2222"), ("相声小品", "2223"), ("百家讲坛", "2224")
        ]
        let half = cats.count / 2
        let m1 = CategoryMenu(title: "小说", categories: cats[0..<half].map { SourceCategory(title: $0.0, url: base + "html/\($0.1).html") })
        let m2 = CategoryMenu(title: "其它", categories: cats[half...].map { SourceCategory(title: $0.0, url: base + "html/\($0.1).html") })
        return [m1, m2]
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        var url = category.url
        if page > 1 {
            url = url.contains("-") && url.range(of: #"-\d+\.html"#, options: .regularExpression) != nil
                ? url.replacingOccurrences(of: #"-\d+\.html"#, with: "-\(page).html", options: .regularExpression)
                : url.replacingOccurrences(of: ".html", with: "-\(page).html")
        }
        let html = try await HTTPClient.text(url, referer: base)
        return parseBooks(html)
    }

    func detail(for book: Book) async throws -> BookDetail {
        let html = try await HTTPClient.text(book.bookURL, referer: base)
        let links = html.allMatches(#"<a[^>]+href="(/mp3/[^"]+)"[^>]*title="([^"]*)""#)
        var episodes: [Episode] = []
        // 上面的正则要求 href 在 title 之前；再补一种顺序
        if links.isEmpty {
            let blocks = html.allMatches(#"(<a[^>]*href="(/mp3/[^"]+)"[^>]*>)"#)
            episodes = blocks.map { Episode(title: "", url: $0.absoluteURL(base: base)) }
        } else {
            let urls = html.allMatches(#"<a[^>]+href="(/mp3/[^"]+)"[^>]*title="([^"]*)""#, group: 1)
            let titles = html.allMatches(#"<a[^>]+href="(/mp3/[^"]+)"[^>]*title="([^"]*)""#, group: 2)
            for (i, u) in urls.enumerated() {
                episodes.append(Episode(title: i < titles.count ? titles[i] : "", url: u.absoluteURL(base: base)))
            }
        }
        var out = BookDetail()
        out.episodes = episodes
        out.intro = html.firstMatch(#"<p class="f-gray[^"]*"[^>]*>([\s\S]*?内容介绍[\s\S]*?)</p>"#)?.strippedTags ?? ""
        if let m = html.firstMatch(#"作者：(.*?)，由(.*?)播音"#, group: 1) { out.author = m }
        if let m = html.firstMatch(#"作者：(.*?)，由(.*?)播音"#, group: 2) { out.artist = m }
        out.cover = html.firstMatch(#"<div class="style-img[\s\S]{0,400}?<img[^>]+src="([^"]+)""#)?.absoluteURL(base: base) ?? book.cover
        return out
    }

    func audioURL(for episode: Episode) async throws -> URL {
        let html = try await HTTPClient.text(episode.url, referer: base)
        guard let raw = html.firstMatch(#"var\s+now\s*=\s*"([^"]+)""#), !raw.isEmpty else {
            throw SourceError.parse("播放页未找到音频地址")
        }
        guard let url = URL(string: raw.absoluteURL(base: base)) else { throw SourceError.badURL(raw) }
        return url
    }

    func verificationURL(keyword: String) -> URL? {
        let kw = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        return URL(string: base + "search.php?searchword=\(kw)")
    }
}

// MARK: - 源查找（统一走 SourceStore：原生源 + 导入的 JSON 规则源）

enum SourceRegistry {
    @MainActor static var all: [any BookSource] { SourceStore.shared.all }
    @MainActor static func source(withId id: String) -> (any BookSource)? {
        SourceStore.shared.all.first { $0.id == id }
    }
}
