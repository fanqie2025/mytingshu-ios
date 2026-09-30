import Foundation

// MARK: - 恋听网（m.ting55.com）
//
// 实测要点：
//  1) 全站 **UTF-8**（不是 GBK）；
//  2) 章节页只给「分集收听(共N集)」+ /book/{id}-{n} 链接，真正的章节标题在 /glink 的 title 字段里；
//  3) 音频直链**不在 HTML 里**：必须 POST /glink，带 `xt` = 章节页 <meta _c>，body 是 bookId/isPay/page，
//     返回 JSON（Content-Type 是 text/plain）里的 `ourl`（优先）或 `url`；
//  4) /glink 的频控按 `mhting55` cookie 计数 —— 每次会话给一个随机 cookie，避免退化成 IP 计数被误封；
//  5) 封面是协议相对地址（//i.ting55.com/...），要补 https:。

final class Ting55Source: BookSource {
    let id = "7a1b2c3d4e5f60718293a4b5c6d7e8f9"
    let name = "恋听网"
    let host = "https://m.ting55.com"
    let desc = "恋听网。音频地址要 POST /glink 换取（已内置，无需 WebView）；本源会自己带随机 cookie 规避频控。"

    private var cookieReady = false

    /// /glink 频控按 cookie 计数：先放一个随机的 mhting55
    private func ensureCookie() {
        guard !cookieReady else { return }
        cookieReady = true
        let hex = (0..<16).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
        HTTPClient.setCookie(name: "mhting55", value: hex, host: host)
    }

    private func get(_ url: String, referer: String? = nil) async throws -> String {
        ensureCookie()
        return try await HTTPClient.text(url, referer: referer ?? host + "/", mobile: true)
    }

    // MARK: - 列表解析

    private func parseList(_ html: String) -> [Book] {
        let doc = HTMLParser.parse(html)
        var nodes = HTMLNode.select("div.clist > a", in: [doc])
        if nodes.isEmpty { nodes = HTMLNode.select("a[href*=/book/]", in: [doc]) }
        var books: [Book] = []
        var seen = Set<String>()
        for a in nodes {
            let href = a.attr("href") ?? ""
            guard href.range(of: #"^/book/\d+$"#, options: .regularExpression) != nil else { continue }
            if !seen.insert(href).inserted { continue }
            let titleAttr = a.attr("title") ?? ""
            var title = titleAttr
            if title.isEmpty { title = HTMLNode.select("h3", in: [a]).first?.allText ?? "" }
            if title.isEmpty { title = HTMLNode.select("p", in: [a]).first?.allText ?? "" }
            if title.isEmpty { title = a.allText }
            title = title.htmlDecoded.strippedTags
            if title.isEmpty { continue }
            let cover = HTMLNode.select("img", in: [a]).first?.attr("src")
                ?? HTMLNode.select("img", in: [a]).first?.attr("data-original") ?? ""
            var artist = HTMLNode.select("span.bys", in: [a]).first?.allText.strippedTags ?? ""
            if artist.isEmpty { artist = HTMLNode.select("a.by", in: [a]).first?.allText.strippedTags ?? "" }
            // 这站的条目里作者/播音在 <p> 文本里
            if artist.isEmpty { artist = a.allText.firstMatch(#"播音：([^<\s]{1,20})"#) ?? "" }
            var author = a.allText.firstMatch(#"作者：([^<\s]{1,20})"#) ?? ""
            if author == "佚名" { author = "" }
            books.append(Book(sourceId: id, title: title, author: author, artist: artist,
                              cover: cover.absoluteURL(base: host), bookURL: href.absoluteURL(base: host)))
        }
        return books
    }

    // MARK: - 搜索与发现

    func search(keyword: String, page: Int) async throws -> [Book] {
        // 搜索是路径段，不是 ?q=
        let enc = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        let html = try await get("\(host)/search/\(enc)")
        return parseList(html)
    }

    func menus() async throws -> [CategoryMenu] {
        let html = try await get(host + "/")
        let doc = HTMLParser.parse(html)
        var cats: [SourceCategory] = []
        var seen = Set<String>()
        for a in HTMLNode.select("nav a", in: [doc]) {
            let href = a.attr("href") ?? ""
            guard href.hasPrefix("/category/"), seen.insert(href).inserted else { continue }
            let t = a.allText.htmlDecoded.strippedTags
            guard !t.isEmpty else { continue }
            cats.append(SourceCategory(title: t, url: href.absoluteURL(base: host)))
        }
        return cats.isEmpty ? [] : [CategoryMenu(title: "分类", categories: cats)]
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        // 第 1 页没有 /page/1
        let url = page <= 1 ? category.url : category.url + "/page/\(page)"
        let html = try await get(url, referer: category.url)
        return parseList(html)
    }

    // MARK: - 详情 / 章节

    func detail(for book: Book) async throws -> BookDetail {
        let html = try await get(book.bookURL)
        var out = BookDetail()
        if let a = html.firstMatch(#"作者：[\s\S]{0,60}?<(?:a|span)[^>]*>([^<]+)</"#) { out.author = a }
        if let b = html.firstMatch(#"播音：[\s\S]{0,60}?<(?:a|span)[^>]*>([^<]+)</"#) { out.artist = b }
        if out.artist.isEmpty {
            out.artist = html.firstMatch(#"<span[^>]*class="bys"[^>]*>([^<]+)</span>"#) ?? ""
        }
        if let c = html.firstMatch(#"<img[^>]+src="([^"]+)""#) { out.cover = c.absoluteURL(base: host) }
        if let i = html.firstMatch(#"简介[\s\S]{0,40}?<p[^>]*>([\s\S]*?)</p>"#) {
            out.intro = i.htmlDecoded.strippedTags
        }

        let doc = HTMLParser.parse(html)
        var episodes: [Episode] = []
        var seen = Set<String>()
        for a in HTMLNode.select("div.plist a", in: [doc]) {
            let href = a.attr("href") ?? ""
            guard href.range(of: #"^/book/\d+-\d+$"#, options: .regularExpression) != nil else { continue }
            if !seen.insert(href).inserted { continue }
            let n = href.split(separator: "-").last.map(String.init) ?? ""
            var t = a.allText.htmlDecoded.strippedTags
            if t.isEmpty || t.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) == nil {
                t = "第 \(n) 集"
            }
            episodes.append(Episode(title: t, url: href.absoluteURL(base: host)))
        }
        // 按集号排序
        episodes.sort { lhs, rhs in
            let l = Int(lhs.url.split(separator: "-").last.map(String.init) ?? "") ?? 0
            let r = Int(rhs.url.split(separator: "-").last.map(String.init) ?? "") ?? 0
            return l < r
        }
        if episodes.isEmpty { throw SourceError.parse("没解析到章节") }
        out.episodes = episodes
        return out
    }

    // MARK: - 音频（POST /glink）

    func audioURL(for episode: Episode) async throws -> URL {
        ensureCookie()
        let page = try await get(episode.url)
        let xt = RuleExtractor.meta("_c", in: page)
        let bookId = RuleExtractor.meta("_b", in: page)
        let isPay = RuleExtractor.meta("_h", in: page)
        let cp = RuleExtractor.meta("_cp", in: page)
        guard !xt.isEmpty, !bookId.isEmpty else { throw SourceError.parse("章节页缺少必要参数") }

        let body = "bookId=\(bookId)&isPay=\(isPay.isEmpty ? "0" : isPay)&page=\(cp.isEmpty ? "1" : cp)"
        let resp = try await HTTPClient.postForm(host + "/glink", body: body,
                                                headers: ["xt": xt, "X-Requested-With": "XMLHttpRequest",
                                                          "Referer": episode.url],
                                                referer: episode.url, mobile: true)
        guard let data = resp.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.parse("/glink 返回不是 JSON")
        }
        let status = (obj["status"] as? Int) ?? Int(anyString(obj["status"])) ?? 0
        if status < 0 {
            throw SourceError.parse("恋听网提示请求过于频繁，过几分钟再试（或换一集）")
        }
        var urlText = anyString(obj["ourl"])
        if urlText.isEmpty { urlText = anyString(obj["url"]) }
        guard !urlText.isEmpty, let u = URL(string: percentEncodedIfNeeded(urlText)) else {
            throw SourceError.parse("/glink 没返回音频地址")
        }
        return u
    }
}
