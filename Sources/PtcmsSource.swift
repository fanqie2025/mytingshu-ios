import Foundation

// MARK: - PTCMS 站点源（爱听书 www.itingshu.net / 13听书网 www.ting13.cc）
//
// 两家同一套程序、同一个书库，差别只有域名与章节目录前缀。
// 关键点（都来自实测逆向）：
//  1) 列表/搜索用手机 UA；章节目录页与播放页**必须桌面 UA**（手机 UA 一律 429）；
//  2) 章节目录路径（/itingshus/{h1}/{h2}.html）是渲染时随机生成的，必须从书籍页的 a.dirurl 现取；
//  3) 音频地址只能由播放页 meta（_b/_p/_c/_d）+ POST /api/mapi/play 换取，
//     请求头要带 sc=<_c> 与 sp=makeSP(<_c>)，sp 是混淆函数，已在此复刻；
//  4) 音频接口被限流时返回 HTTP 200 但 status!=200，且 url 是随机诱饵 —— 必须校验 status，
//     失败要重新拉播放页换新的 _c 再试。
//  5) 任意页面可能返回 51.LA 的 JS 挑战（var reversed=…），解开后写 __51guid__ cookie 重放。

final class PtcmsSource: BookSource {
    let id: String
    let name: String
    let host: String            // https://www.itingshu.net
    let dirPrefix: String       // /itingshus/ 或 /tingdirs/
    let desc: String

    init(id: String, name: String, host: String, dirPrefix: String, desc: String) {
        self.id = id
        self.name = name
        self.host = host
        self.dirPrefix = dirPrefix
        self.desc = desc
    }

    // MARK: - 请求（含 429 换 UA、51.LA 挑战）

    private func once(_ url: String, desktop: Bool, form: String? = nil) async throws -> String {
        if let form {
            return try await HTTPClient.postForm(url, body: form, referer: host + "/", mobile: !desktop)
        }
        return try await HTTPClient.text(url, referer: host + "/", mobile: !desktop)
    }

    private func fetch(_ url: String, desktop: Bool, form: String? = nil) async throws -> String {
        var text: String
        do {
            text = try await once(url, desktop: desktop, form: form)
        } catch SourceError.http(let code, _) where code == 429 {
            // 命中限流：换另一种 UA 再试一次
            text = try await once(url, desktop: !desktop, form: form)
        }
        if text.contains("var reversed") || text.contains("__51guid__") {
            if let token = Self.solveGuard(text) {
                Self.setGuardCookie(token, host: host)
                text = try await once(url, desktop: desktop, form: form)
            }
        }
        return text
    }

    /// 解 51.LA 的 JS 挑战：var reversed → 反转 → base64 → 里面写着 __51guid__ 的 token
    static func solveGuard(_ html: String) -> String? {
        guard let raw = html.firstMatch(#"var\s+reversed\s*=\s*"([^"]+)""#) else { return nil }
        let forward = String(raw.reversed())
        let padded = forward + String(repeating: "=", count: (4 - forward.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let js = String(data: data, encoding: .utf8) else { return nil }
        if let m = js.firstMatch(#"__51guid__=([^;'"\\]+)"#) { return m }
        if let m = js.firstMatch(#"token\s*=\s*['"]([^'"]+)['"]"#) { return m }
        return nil
    }

    static func setGuardCookie(_ token: String, host: String) {
        guard let h = URL(string: host)?.host else { return }
        let props: [HTTPCookiePropertyKey: Any] = [
            .domain: h, .path: "/", .name: "__51guid__", .value: token
        ]
        if let c = HTTPCookie(properties: props) { HTTPCookieStorage.shared.setCookie(c) }
    }

    // MARK: - 列表解析（搜索页与分类页结构一致）

    private func parseList(_ html: String) -> [Book] {
        let doc = HTMLParser.parse(html)
        let items = HTMLNode.select("dl.list-works-dl", in: [doc])
        var books: [Book] = []
        for it in items {
            let a = HTMLNode.select("dt.list-book-dt > a", in: [it]).first
                ?? HTMLNode.select("dt.list-book-dt a", in: [it]).first
            guard let a else { continue }
            let href = a.attr("href") ?? ""
            var title = a.allText.htmlDecoded.strippedTags
            title = title.replacingOccurrences(of: "有声小说", with: "")
            if title.isEmpty || href.isEmpty { continue }
            // 封面在兄弟节点 div.list-imgbox 里 → 往上找到最近的 li 再找图
            var box: HTMLNode = it
            while let p = box.parent, p.tag != "li" { box = p }
            let cover = HTMLNode.select("img.lazy", in: [box]).first?.attr("data-original")
                ?? HTMLNode.select("img", in: [box]).first?.attr("src") ?? ""
            let author = HTMLNode.select("span.book-author a", in: [it]).first?.allText.strippedTags ?? ""
            let artist = HTMLNode.select("span.book-boyin a", in: [it]).first?.allText.strippedTags ?? ""
            let intro = HTMLNode.select("dd.list-book-des", in: [it]).first?.allText.htmlDecoded.strippedTags ?? ""
            books.append(Book(sourceId: id, title: title, author: author, artist: artist,
                              cover: cover.absoluteURL(base: host), bookURL: href.absoluteURL(base: host),
                              intro: intro))
        }
        return books
    }

    // MARK: - 搜索与发现

    func search(keyword: String, page: Int) async throws -> [Book] {
        let enc = keyword.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? keyword
        let html = try await fetch(host + "/novelsearch/search/result.html",
                                   desktop: false, form: "searchword=\(enc)")
        return parseList(html)
    }

    func menus() async throws -> [CategoryMenu] {
        let html = try await fetch(host + "/", desktop: true)
        var cats: [SourceCategory] = []
        let hrefs = html.allMatches(#"<a\s*href="(/yousheng/[^"]+\.html)""#)
        let titles = html.allMatches(#"<a\s*href="/yousheng/[^"]+\.html"[^>]*>([^<]{1,20})</a>"#)
        for (i, h) in hrefs.enumerated() where i < titles.count {
            let t = titles[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if cats.contains(where: { $0.url == h }) { continue }
            cats.append(SourceCategory(title: t, url: h.absoluteURL(base: host)))
        }
        return cats.isEmpty ? [] : [CategoryMenu(title: "分类", categories: cats)]
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        var url = category.url
        if page > 1 {
            // /yousheng/{slug}/lastupdate.html → /yousheng/{slug}/lastupdate/1/{page}.html
            if url.hasSuffix("/lastupdate.html") {
                url = url.replacingOccurrences(of: "/lastupdate.html", with: "/lastupdate/1/\(page).html")
            } else if url.hasSuffix(".html") {
                url = url.replacingOccurrences(of: ".html", with: "/1/\(page).html")
            }
        }
        let html = try await fetch(url, desktop: false)
        return parseList(html)
    }

    // MARK: - 详情（书籍页 → 章节目录页）

    func detail(for book: Book) async throws -> BookDetail {
        let page = try await fetch(book.bookURL, desktop: false)
        var out = BookDetail()
        out.intro = page.firstMatch(#"<meta\s+name="description"\s+content="([^"]*)""#) ?? book.intro
        if let a = page.firstMatch(#"作者：[\s\S]{0,80}?<a[^>]*>([^<]+)</a>"#) { out.author = a }
        if let b = page.firstMatch(#"(?:演播|播讲)：[\s\S]{0,80}?<a[^>]*>([^<]+)</a>"#) { out.artist = b }
        if out.artist.isEmpty { out.artist = book.artist }
        out.cover = page.firstMatch(#"<img[^>]*src="(https://image\.itingshu\.net/[^"]+)""#) ?? book.cover

        // 章节目录入口（路径随机，必须现取）
        guard let dirPath = page.firstMatch(#"class="dirurl"[^>]*href="([^"]+)""#)
                ?? page.firstMatch(#"href="([^"]*"# + NSRegularExpression.escapedPattern(for: dirPrefix) + #"[^"]+)""#) else {
            throw SourceError.parse("书籍页没找到章节目录入口")
        }
        let dirURL = dirPath.absoluteURL(base: host)

        var episodes: [Episode] = []
        var seen = Set<String>()
        var pageNo = 1
        while pageNo <= 40 {
            let sep = dirURL.contains("?") ? "&" : "?"
            let u = pageNo == 1 ? "\(dirURL)\(sep)sort=asc" : "\(dirURL)\(sep)page=\(pageNo)&sort=asc"
            let html = try await fetch(u, desktop: true)   // 目录页必须桌面 UA
            let doc = HTMLParser.parse(html)
            var nodes = HTMLNode.select("#playlist li a", in: [doc])
            if nodes.isEmpty { nodes = HTMLNode.select("li.chapter-item a", in: [doc]) }
            var added = 0
            for a in nodes {
                let href = a.attr("href") ?? ""
                guard href.contains("/play/"), !seen.contains(href) else { continue }
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

    // MARK: - 音频（签名接口）

    private static let alphabet = Array("PXhw7U1B0a9kQDKZsTjIASmOeNzxYG4CHo1JyRfg2b8FLpEvr3FtVnlqMidu6c")

    /// 复刻混淆函数：每个字符输出三位＝[随机][原字符在字母表中后移 3 位][随机]
    static func makeSP(_ sc: String) -> String {
        var out = ""
        for ch in sc {
            if let idx = alphabet.firstIndex(of: ch) {
                out.append(alphabet[Int.random(in: 0..<alphabet.count)])
                out.append(alphabet[(idx + 3) % alphabet.count])
                out.append(alphabet[Int.random(in: 0..<alphabet.count)])
            } else {
                for _ in 0..<3 { out.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
            }
        }
        return out
    }

    func audioURL(for episode: Episode) async throws -> URL {
        for _ in 0..<3 {
            let page = try await fetch(episode.url, desktop: true)
            let nid = RuleExtractor.meta("_b", in: page)
            let cid = RuleExtractor.meta("_p", in: page)
            let sc = RuleExtractor.meta("_c", in: page)
            var sort = RuleExtractor.meta("_d", in: page)
            if sort.isEmpty { sort = "read" }
            guard !nid.isEmpty, !cid.isEmpty, !sc.isEmpty else { continue }  // 空壳页（被限流）→ 重试

            let body = "nid=\(nid)&cid=\(cid)&sort=\(sort)"
            let resp = try await HTTPClient.postForm(host + "/api/mapi/play", body: body,
                                                    headers: ["sc": sc, "sp": Self.makeSP(sc),
                                                              "X-Requested-With": "XMLHttpRequest",
                                                              "Referer": episode.url],
                                                    referer: episode.url, mobile: false)
            if let data = resp.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let status = (obj["status"] as? Int) ?? Int(anyString(obj["status"])) ?? 0
                var urlText = anyString(obj["url"])
                // 已知坑：mp3pd.ting13.top 的 https 证书过期，改走 http 才放得出声
                if urlText.hasPrefix("https://mp3pd.") {
                    urlText = "http://" + urlText.dropFirst("https://".count)
                }
                if status == 200, !urlText.isEmpty, let u = URL(string: percentEncodedIfNeeded(urlText)) {
                    return u
                }
            }
            // status != 200：接口被限流，换新的 _c 再来
        }
        throw SourceError.parse("音频接口一直返回失败（可能被限流，过一会儿再试这一集）")
    }
}
