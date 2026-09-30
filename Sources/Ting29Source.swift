import Foundation

// MARK: - 29听书网（m.ting29.com + www.ting29.com）
//
// 实测要点：
//  1) 分类列表与搜索都是 JSON 接口，参数从分类页内联的 `var __API_*` 读，别硬编码 key；
//  2) `/tingshu/...` 与 `/bookdir/...` 走 JS Cookie 守卫（pt_guid，反转+base64），且**无效路径也先返回守卫页**；
//  3) 音频：移动播放页的播放器封在 328KB 混淆 JS 里，但 **PC 站 `/player.html?nid=&cid=&site=16` 是纯 HTML 直出地址**
//     （`m.ting29.com/player.html` 是 404，只有 www 有）。页面里变量名随机、拼接形态有 3 种，
//     所以要**求值 `mp3:` 那个字符串拼接表达式**，不能写死正则。

final class Ting29Source: BookSource {
    let id = "29a11c0de5f60718293a4b5c6d7e8f90"
    let name = "29听书网"
    let host = "https://m.ting29.com"
    let pcHost = "https://www.ting29.com"
    let desc = "29听书网（安安听书网）。分类/搜索走 JSON 接口，音频从 PC 播放页取（已内置，无需 WebView）。"

    // MARK: - 请求（含 pt_guid 守卫）

    private func raw(_ url: String, referer: String? = nil, desktop: Bool = false) async throws -> String {
        try await HTTPClient.text(url, referer: referer ?? host + "/", mobile: !desktop)
    }

    private func fetch(_ url: String, referer: String? = nil, desktop: Bool = false) async throws -> String {
        var text = try await raw(url, referer: referer, desktop: desktop)
        if text.contains("var reversed") || text.contains("pt_guid") {
            if let token = HTTPClient.solveGuardToken(text, cookieName: "pt_guid") {
                HTTPClient.setCookie(name: "pt_guid", value: token, host: host)
                HTTPClient.setCookie(name: "ptcms_guard_retry", value: "1", host: host)
                text = try await raw(url, referer: referer, desktop: desktop)
            }
        }
        return text
    }

    // MARK: - JSON 列表（分类 / 搜索共用）

    private func books(fromJSON text: String) -> [Book] {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var items: [[String: Any]] = []
        if let dict = obj as? [String: Any], let arr = dict["data"] as? [[String: Any]] {
            items = arr
        } else if let arr = obj as? [[String: Any]] {
            items = arr
        }
        var books: [Book] = []
        for it in items {
            let node = (it["novel"] as? [String: Any]) ?? it
            var url = anyString(node["url"])
            let title = cleanText(node["title"] ?? node["name"])
            guard !title.isEmpty else { continue }
            if url.isEmpty { url = anyString(node["bookurl"]) }
            guard !url.isEmpty else { continue }
            if !url.hasPrefix("http") {
                url = url.hasPrefix("/") ? host + url : host + "/" + url
            }
            books.append(Book(sourceId: id,
                              title: title,
                              artist: anyString(node["boyin"]),
                              cover: anyString(node["pic"] ?? node["cover"]).absoluteURL(base: host),
                              bookURL: url,
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
            let gname = HTMLNode.select("dt a", in: [group]).first?.allText.htmlDecoded.strippedTags ?? "分类"
            var cats: [SourceCategory] = []
            for a in HTMLNode.select("dd a", in: [group]) {
                let href = a.attr("href") ?? ""
                guard href.hasPrefix("/book/") else { continue }
                var t = (a.attr("title") ?? a.allText).htmlDecoded.strippedTags
                t = t.replacingOccurrences(of: "小说", with: "")
                guard !t.isEmpty else { continue }
                cats.append(SourceCategory(title: t, url: href.absoluteURL(base: host)))
            }
            if !cats.isEmpty { menus.append(CategoryMenu(title: gname, categories: cats)) }
        }
        return menus
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        let html = try await fetch(category.url)
        func varValue(_ name: String) -> String {
            html.firstMatch(#"var\s+\#(name)\s*=\s*['"]([^'"]*)['"]"#) ?? ""
        }
        let sort = varValue("__API_SORT").isEmpty ? "1" : varValue("__API_SORT")
        let key = varValue("__API_KEY")
        let tg = varValue("__API_TG")
        let order = varValue("__API_ORDER").isEmpty ? "1" : varValue("__API_ORDER")
        guard !key.isEmpty else { throw SourceError.parse("分类页没读到 key") }
        let api = "\(host)/api/ajax/list?sort=\(sort)&key=\(key)&tg=\(tg)&order=\(order)&page=\(page)"
        let text = try await fetch(api, referer: category.url)
        return books(fromJSON: text)
    }

    // MARK: - 详情 / 章节（走 /bookdir/，需要守卫）

    func detail(for book: Book) async throws -> BookDetail {
        let page = try await fetch(book.bookURL)
        var out = BookDetail()
        if let a = page.firstMatch(#"播音：[\s\S]{0,60}?<(?:a|span)[^>]*>([^<]+)</"#) { out.artist = a }
        if let img = page.firstMatch(#"<img[^>]+(?:data-original|src)="([^"]+)""#) {
            out.cover = img.absoluteURL(base: host)
        }
        if let i = page.firstMatch(#"简介[\s\S]{0,60}?<p[^>]*>([\s\S]*?)</p>"#) {
            out.intro = i.htmlDecoded.strippedTags
        }

        guard let dirPath = page.firstMatch(#"href="([^"]*bookdir[^"]*)""#) else {
            throw SourceError.parse("详情页没找到全量目录入口")
        }
        let dirURL = dirPath.absoluteURL(base: host)

        var episodes: [Episode] = []
        var seen = Set<String>()
        var pageNo = 1
        while pageNo <= 60 {
            let sep = dirURL.contains("?") ? "&" : "?"
            let u = pageNo == 1 ? dirURL : "\(dirURL)\(sep)page=\(pageNo)"
            let html = try await fetch(u)
            let doc = HTMLParser.parse(html)
            var nodes = HTMLNode.select("a[href*=/tingshu/]", in: [doc])
            if nodes.isEmpty { nodes = HTMLNode.select("#playlist li a", in: [doc]) }
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
        if episodes.isEmpty { throw SourceError.parse("没解析到章节（可能守卫没过）") }
        out.episodes = episodes
        return out
    }

    // MARK: - 音频（PC /player.html + 表达式求值）

    func audioURL(for episode: Episode) async throws -> URL {
        // /tingshu/{book}/{cid}.html
        let parts = episode.url.split(separator: "/")
        guard parts.count >= 2 else { throw SourceError.parse("章节链接异常") }
        let cid = String(parts[parts.count - 1]).replacingOccurrences(of: ".html", with: "")
        let bookId = String(parts[parts.count - 2])
        let player = "\(pcHost)/player.html?nid=\(bookId)&cid=\(cid)&site=16"
        let html = try await fetch(player, referer: pcHost + "/", desktop: true)
        guard let u = Self.resolveMediaURL(html), let url = URL(string: percentEncodedIfNeeded(u)) else {
            throw SourceError.parse("PC 播放页没解析出音频地址")
        }
        return url
    }

    /// 求值 `mp3:` 后面的字符串拼接表达式（变量名每次随机，形态有 3 种）
    static func resolveMediaURL(_ html: String) -> String? {
        let names = html.allMatches(#"var\s+([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*['"]"#)
        let values = html.allMatches(#"var\s+[A-Za-z_][A-Za-z0-9_$]*\s*=\s*['"]([^'"]*)['"]"#)
        var vars: [String: String] = [:]
        for (i, n) in names.enumerated() where i < values.count { vars[n] = values[i] }

        if let rawExpr = html.firstMatch(#"\bmp3\s*:\s*([^\n\r]+)"#) {
            let expr = rawExpr.split(separator: ",").first.map(String.init) ?? rawExpr
            var parts: [String] = []
            var buf = ""
            var quote: Character?
            for ch in expr {
                if let q = quote {
                    if ch == q { quote = nil }
                    buf.append(ch)
                } else if ch == "'" || ch == "\"" {
                    quote = ch
                    buf.append(ch)
                } else if ch == "+" {
                    parts.append(buf); buf = ""
                } else {
                    buf.append(ch)
                }
            }
            parts.append(buf)

            var out = ""
            var ok = true
            for p in parts {
                let t = p.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty { continue }
                if t.hasPrefix("'") || t.hasPrefix("\"") {
                    if t.count >= 2 { out += String(t.dropFirst().dropLast()) }
                } else if let v = vars[t] {
                    out += v
                } else {
                    ok = false
                    break
                }
            }
            if ok, out.hasPrefix("http") { return out }
        }
        // 兜底：整页找第一个音频地址
        return html.firstMatch(#"(https?://[^'"\s<>]+\.(?:mp3|m4a|aac))"#)
    }
}
