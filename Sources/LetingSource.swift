import Foundation

// MARK: - 乐听网（m.leting.vip）
//
// 站点特殊性（都来自实测）：
//  1) **必须用手机站 m.leting.vip**：桌面站没有 salt meta、也没有 readplay 接口，拿不到音频；
//  2) 章节页/目录页会先返回一段「反转 + base64」的 JS 挑战，解出 pt_guid 写 cookie 后重放即可（纯 HTTP 可破）；
//  3) 分类列表是 AJAX：页面里内联 var __API_SORT/__API_KEY/__API_TG/__API_ORDER，拿去请求 /api/ajax/list；
//  4) 音频：章节页 3 个 meta（_b/_p/_c=salt）→ POST /api/act/readplay，
//     载荷是**双层编码**：先 urlquote 内层 JSON（safe=""），再整体 base64，塞进 {"encodedData": "..."}；
//  5) 目录路径 /bookdir/{seg1}/{seg2}.html 的 seg2 每次都变 —— 必须从详情页现取 a.dirurl。

final class LetingSource: BookSource {
    let id = "1e71e70000000000000000000000abcd"
    let name = "乐听网"
    let host = "https://m.leting.vip"
    let desc = "乐听网（一千多本有声书）。分类走 AJAX 接口；音频地址要用页面 salt 换，本源已处理。"

    // MARK: - 请求（含 pt_guid 挑战）

    private func raw(_ url: String, referer: String? = nil, extra: [String: String] = [:]) async throws -> String {
        var headers = extra
        headers["X-Requested-With"] = headers["X-Requested-With"] ?? "XMLHttpRequest"
        return try await HTTPClient.text(url, headers: headers, referer: referer ?? host + "/", mobile: true)
    }

    private func fetch(_ url: String, referer: String? = nil) async throws -> String {
        var text = try await raw(url, referer: referer)
        var left = 2
        while left > 0, text.contains("var reversed") {
            let cookies = HTTPClient.solveGuardCookies(text)
            if cookies.isEmpty { break }
            HTTPClient.applyGuardCookies(cookies, host: host)
            text = try await raw(url, referer: referer)
            left -= 1
        }
        return text
    }

    // MARK: - 解析

    private func books(fromJSON text: String) -> [Book] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        // 两种形态：{"data":[{...}]} 与裸数组 [{"novel":{...}}]
        var rawItems: [[String: Any]] = []
        if let dict = obj as? [String: Any], let arr = dict["data"] as? [[String: Any]] {
            rawItems = arr
        } else if let arr = obj as? [[String: Any]] {
            rawItems = arr
        }
        var books: [Book] = []
        for item in rawItems {
            let node = (item["novel"] as? [String: Any]) ?? item
            let url = anyString(node["url"])
            let title = cleanText(node["title"] ?? node["name"])
            guard !url.isEmpty, !title.isEmpty else { continue }
            books.append(Book(sourceId: id,
                              title: title,
                              artist: anyString(node["boyin"]),
                              cover: anyString(node["pic"] ?? node["cover"]).absoluteURL(base: host),
                              bookURL: url.absoluteURL(base: host),
                              intro: cleanText(node["content"] ?? node["intro"])))
        }
        return books
    }

    // MARK: - 搜索 / 发现

    func search(keyword: String, page: Int) async throws -> [Book] {
        let enc = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        let text = try await fetch("\(host)/api/ajax/solist?word=\(enc)&type=name&page=\(page)&order=1")
        return books(fromJSON: text)
    }

    func menus() async throws -> [CategoryMenu] {
        let html = try await fetch(host + "/sort/")
        let doc = HTMLParser.parse(html)
        var menus: [CategoryMenu] = []
        for group in HTMLNode.select("dl.pd-class", in: [doc]) {
            let title = HTMLNode.select("dt", in: [group]).first?.allText.htmlDecoded.strippedTags ?? "分类"
            var cats: [SourceCategory] = []
            for a in HTMLNode.select("dd a", in: [group]) {
                let href = a.attr("href") ?? ""
                let t = a.allText.htmlDecoded.strippedTags
                guard !href.isEmpty, !t.isEmpty else { continue }
                cats.append(SourceCategory(title: t, url: href.absoluteURL(base: host)))
            }
            if !cats.isEmpty { menus.append(CategoryMenu(title: title, categories: cats)) }
        }
        return menus
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        // 分类页里内联了 AJAX 参数，先取参数再调接口
        let html = try await fetch(category.url)
        func varValue(_ name: String) -> String {
            // 注意：这些内联变量有时结尾没有分号
            html.firstMatch(#"var\s+\#(name)\s*=\s*['"]([^'"]*)['"]"#) ?? ""
        }
        let sort = varValue("__API_SORT").isEmpty ? "1" : varValue("__API_SORT")
        let key = varValue("__API_KEY").isEmpty ? "1" : varValue("__API_KEY")
        let tg = varValue("__API_TG")
        let order = varValue("__API_ORDER").isEmpty ? "1" : varValue("__API_ORDER")
        let api = "\(host)/api/ajax/list?sort=\(sort)&key=\(key)&tg=\(tg)&order=\(order)&page=\(page)"
        let text = try await fetch(api, referer: category.url)
        return books(fromJSON: text)
    }

    // MARK: - 详情（书籍页 → 全部章节）

    func detail(for book: Book) async throws -> BookDetail {
        let page = try await fetch(book.bookURL)
        var out = BookDetail()
        out.cover = page.firstMatch(#"<img[^>]*src="([^"]+)"[^>]*class="book-cover""#)
            ?? page.firstMatch(#"<img[^>]*class="book-cover"[^>]*src="([^"]+)""#) ?? book.cover
        if let a = page.firstMatch(#"演播：[\s\S]{0,60}?<a[^>]*>([^<]+)</a>"#) { out.artist = a }
        if let b = page.firstMatch(#"作者：[\s\S]{0,60}?<a[^>]*>([^<]+)</a>"#) { out.author = b }
        if let i = page.firstMatch(#"<div[^>]*class="[^"]*intro[^"]*"[^>]*>([\s\S]*?)</div>"#) {
            out.intro = i.htmlDecoded.strippedTags
        }

        guard let dirPath = page.firstMatch(#"<a[^>]*href="([^"]*bookdir[^"]*)"#) else {
            throw SourceError.parse("详情页没找到章节目录入口")
        }
        let dirURL = dirPath.absoluteURL(base: host)

        var episodes: [Episode] = []
        var seen = Set<String>()
        var pageNo = 1
        while pageNo <= 60 {
            let sep = dirURL.contains("?") ? "&" : "?"
            let u = pageNo == 1 ? "\(dirURL)\(sep)sort=asc" : "\(dirURL)\(sep)page=\(pageNo)&sort=asc"
            let html = try await fetch(u)
            let doc = HTMLParser.parse(html)
            var nodes = HTMLNode.select("#playlist li a", in: [doc])
            if nodes.isEmpty { nodes = HTMLNode.select("a[href*=/tingshu/]", in: [doc]) }
            var added = 0
            for a in nodes {
                let href = a.attr("href") ?? ""
                guard href.contains("/tingshu/"), !seen.contains(href) else { continue }
                seen.insert(href)
                let t = a.attr("title") ?? a.allText.htmlDecoded.strippedTags
                episodes.append(Episode(title: t, url: href.absoluteURL(base: host)))
                added += 1
            }
            if added == 0 || nodes.count < 50 { break }
            pageNo += 1
        }
        if episodes.isEmpty { throw SourceError.parse("没解析到章节") }
        out.episodes = episodes
        return out
    }

    // MARK: - 音频（salt + readplay）

    func audioURL(for episode: Episode) async throws -> URL {
        for _ in 0..<3 {
            let page = try await fetch(episode.url)
            let novelid = RuleExtractor.meta("_b", in: page)
            let chapterid = RuleExtractor.meta("_p", in: page)
            let salt = RuleExtractor.meta("_c", in: page)
            guard !novelid.isEmpty, !chapterid.isEmpty, !salt.isEmpty else { continue }

            // 内层 JSON → urlquote(safe="") → base64 → 外层 JSON
            let inner = #"{"novelid":"\#(novelid)","chapterid":"\#(chapterid)","type":1,"salt":"\#(salt)"}"#
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let quoted = inner.addingPercentEncoding(withAllowedCharacters: unreserved) ?? inner
            let encoded = Data(quoted.utf8).base64EncodedString()
            let payload = #"{"encodedData":"\#(encoded)"}"#

            let resp = try await HTTPClient.postJSON(host + "/api/act/readplay", json: payload,
                                                    headers: ["Origin": host, "Referer": episode.url],
                                                    referer: episode.url, mobile: true)
            if let data = resp.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let urlText = anyString(obj["audioUrl"])
                if !urlText.isEmpty, let u = URL(string: percentEncodedIfNeeded(urlText)) {
                    return u
                }
            }
        }
        throw SourceError.parse("音频接口没返回地址（可能被限流，稍后再试这一集）")
    }
}
