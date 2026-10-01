import Foundation

// MARK: - JSON 书源规则（导入书源用）

/// 一个可导入的书源定义。字段都可选，按需填。
struct SourceRule: Codable, Identifiable {
    var id: String
    var name: String
    var host: String
    var desc: String?
    var encoding: String?          // "utf-8"（默认）或 "gbk"
    var ua: String?                // "mobile"（默认）或 "desktop"（有些站会对手机 UA 跳转）
    var warmup: String?            // 首次请求前先 GET 这个地址拿 Cookie/session
    var searchable: Bool?
    var discoverable: Bool?
    var headers: [String: String]?

    var search: ListRule?
    var categories: [CategoryRule]?
    var detail: DetailRule?
    var audio: AudioRule?
    var verification: VerificationRule?

    struct CategoryRule: Codable {
        var title: String
        var url: String
        var group: String?
    }

    struct ListRule: Codable {
        var url: String                    // 第 1 页；支持 {kw} {page} {host}
        var pageUrl: String?               // 第 2 页起（含 {page}），不填则用 url 替换 {page}
        var list: String                   // 条目容器选择器
        var title: String                  // 取值规则，如 "h2 a@text"
        var urlRule: String?               // 条目链接取值，如 "h2 a@href"（默认同 title 的 @href）
        var cover: String?
        var artist: String?
        var author: String?
        var intro: String?
        var encoding: String?
        // v2：POST 搜索 / 每步 UA
        var method: String?                // "get"（默认）| "post"
        var body: String?                  // POST 表单体（支持 {kw} {page}）
        var ua: String?                    // 本步骤 UA："mobile" | "desktop"
        var headers: [String: String]?
    }

    struct DetailRule: Codable {
        var episodes: String               // 章节容器/链接选择器
        var episodeTitle: String?          // 默认 "@title"
        var episodeUrl: String?            // 默认 "@href"
        var intro: String?
        var cover: String?
        var artist: String?
        var author: String?
        var encoding: String?
        // v2：两步取目录（详情页 → 目录页）
        var ua: String?                    // 详情页 UA
        var dirUrl: String?                // 目录入口取值规则（如 "a.dirurl@href"）
        var dirUA: String?                 // 目录页 UA（PTCMS 要桌面 UA）
        var pages: PageRule?               // 目录分页

        struct PageRule: Codable {
            var url: String                // 支持 {dir} {page}
            var max: Int?                  // 最多翻多少页（默认 60）
        }
    }

    struct AudioRule: Codable {
        var type: String                   // regex | direct | json | redirect | post | pcPlayer
        var pattern: String?               // regex / redirect 用
        var field: String?                 // json / post 用（点号路径）
        var fieldAlt: String?              // field 取不到时再试这个（恋听网 ourl→url）
        var prefix: String?                // 相对地址前缀
        var referer: String?               // 播放时的 Referer（支持 {host} {episodeUrl}）
        var headers: [String: String]?     // 请求头（值可含 {meta变量}）
        var url: String?                   // post 用：接口地址
        var body: String?                  // post 用：表单体模板
        var metaFrom: [String: String]?    // post 用：变量名 -> 章节页 <meta name="...">
        var metaDefaults: [String: String]?
        // v2：重试 / 校验 / 签名 / 改写
        var retries: Int?                  // 失败重试次数（每次重新拉章节页，默认 1）
        var statusField: String?           // 返回体里的状态字段（如 "status"）
        var statusOK: String?              // 状态等于它才算成功（如 "200"）
        var ua: String?                    // 拉章节页用的 UA（PTCMS 这类要桌面 UA）
        var sign: Sign?                    // 生成签名
        var replace: [[String]]?           // 地址改写，如 [["https://mp3pd.","http://mp3pd."]]
        var cookies: [String: String]?     // 请求前写的 cookie（值 "randHex16" 表示随机 16 位 hex）

        struct Sign: Codable {
            var kind: String               // ptcmsSp | md5 | base64Quote
            var input: String?             // 输入模板（可用 {meta变量}）
            var alphabet: String?          // ptcmsSp 用
            var header: String?            // 放进请求头（否则放进 body 参数）
            var param: String?             // 放进 body 的参数名
        }
    }

    struct VerificationRule: Codable {
        var url: String                    // 支持 {kw}
    }
}

// MARK: - 规则驱动的源

final class RuleSource: BookSource {
    let rule: SourceRule

    init(rule: SourceRule) { self.rule = rule }

    var id: String { rule.id }
    var name: String { rule.name }
    var host: String { rule.host }
    var desc: String { rule.desc ?? "" }
    var searchable: Bool { rule.searchable ?? (rule.search != nil) }
    var discoverable: Bool { rule.discoverable ?? (rule.categories?.isEmpty == false) }
    var needsVerification: Bool { rule.verification != nil }

    private var base: String {
        var h = rule.host
        if !h.hasSuffix("/") { h += "/" }
        return h
    }

    private func fill(_ template: String, kw: String? = nil, page: Int? = nil, extra: [String: String] = [:]) -> String {
        var s = template
        s = s.replacingOccurrences(of: "{host}", with: rule.host)
        if let kw {
            let enc = kw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? kw
            s = s.replacingOccurrences(of: "{kw}", with: enc)
        }
        if let page { s = s.replacingOccurrences(of: "{page}", with: "\(page)") }
        for (k, v) in extra { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        if s.hasPrefix("http") { return s }
        if s.hasPrefix("/") { return rule.host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + s }
        return base + s
    }

    private func fetch(_ url: String, gbk: Bool = false, desktop: Bool? = nil,
                       form: String? = nil, extraHeaders: [String: String] = [:]) async throws -> String {
        await ensureWarmup()
        var headers = rule.headers ?? [:]
        for (k, v) in extraHeaders { headers[k] = v }
        if headers["Referer"] == nil { headers["Referer"] = base }
        let useDesktop = desktop ?? ((rule.ua ?? "mobile").lowercased() == "desktop")

        func once() async throws -> String {
            if let form {
                return try await HTTPClient.postForm(url, body: form, headers: headers,
                                                     referer: base, mobile: !useDesktop)
            }
            return try await HTTPClient.text(url, gbk: gbk, headers: headers,
                                             referer: base, mobile: !useDesktop)
        }

        var text = try await once()
        // 任何页面都可能撞上「反转 + base64」型 JS Cookie 守卫 —— 规则源也自动解开重放
        var left = 2
        while left > 0, text.contains("var reversed") {
            let cookies = HTTPClient.solveGuardCookies(text)
            if cookies.isEmpty { break }
            HTTPClient.applyGuardCookies(cookies, host: rule.host)
            text = try await once()
            left -= 1
        }
        return text
    }

    /// 有些站必须先访问首页拿到 session，否则详情/播放页返回的是首页（状态码仍是 200）
    private static var warmed = Set<String>()
    private static let warmLock = NSLock()

    private func ensureWarmup() async {
        guard let w = rule.warmup, !w.isEmpty else { return }
        RuleSource.warmLock.lock()
        let need = !RuleSource.warmed.contains(id)
        if need { RuleSource.warmed.insert(id) }
        RuleSource.warmLock.unlock()
        guard need else { return }
        _ = try? await HTTPClient.text(fill(w), referer: base,
                                       mobile: (rule.ua ?? "mobile").lowercased() != "desktop")
    }

    private func parseList(_ html: String, using lr: SourceRule.ListRule) -> [Book] {
        let doc = HTMLParser.parse(html)
        let nodes = HTMLNode.select(lr.list, in: [doc])
        let useGBK = (lr.encoding ?? rule.encoding ?? "utf-8").lowercased().contains("gb")
        _ = useGBK
        var books: [Book] = []
        for node in nodes {
            let title = RuleExtractor.value(lr.title, in: [node])
            if title.isEmpty { continue }
            var url = ""
            if let ur = lr.urlRule { url = RuleExtractor.value(ur, in: [node]) }
            if url.isEmpty { url = RuleExtractor.value(lr.title.replacingOccurrences(of: "@text", with: "@href"), in: [node]) }
            guard !url.isEmpty else { continue }
            let cover = lr.cover.map { RuleExtractor.value($0, in: [node]) } ?? ""
            let artist = lr.artist.map { RuleExtractor.value($0, in: [node]) } ?? ""
            let author = lr.author.map { RuleExtractor.value($0, in: [node]) } ?? ""
            let intro = lr.intro.map { RuleExtractor.value($0, in: [node]) } ?? ""
            books.append(Book(sourceId: id,
                              title: title,
                              author: author,
                              artist: artist,
                              cover: cover.absoluteURL(base: base),
                              bookURL: url.absoluteURL(base: base),
                              intro: intro))
        }
        return books
    }

    func search(keyword: String, page: Int) async throws -> [Book] {
        guard let sr = rule.search else { return [] }
        let url = fill(sr.url, kw: keyword, page: page)
        let gbk = (sr.encoding ?? rule.encoding ?? "utf-8").lowercased().contains("gb")
        let desktop = (sr.ua ?? rule.ua ?? "mobile").lowercased() == "desktop"
        var form: String? = nil
        if (sr.method ?? "get").lowercased() == "post" {
            form = fill(sr.body ?? "searchword={kw}", kw: keyword, page: page)
        }
        let html = try await fetch(url, gbk: gbk, desktop: desktop, form: form,
                                   extraHeaders: sr.headers ?? [:])
        if html.contains("系统安全验证") && needsVerification { throw SourceError.needVerification }
        return parseList(html, using: sr)
    }

    func menus() async throws -> [CategoryMenu] {
        guard let cats = rule.categories, !cats.isEmpty else { return [] }
        var groups: [String: [SourceCategory]] = [:]
        for c in cats {
            let g = c.group ?? "分类"
            groups[g, default: []].append(SourceCategory(title: c.title, url: fill(c.url)))
        }
        return groups.keys.sorted().map { CategoryMenu(title: $0, categories: groups[$0] ?? []) }
    }

    func books(in category: SourceCategory, page: Int) async throws -> [Book] {
        guard let lr = rule.search ?? listRuleFromDetail() else { return [] }
        var url = category.url
        if page > 1 {
            if let tpl = lr.pageUrl, !tpl.isEmpty {
                url = fill(tpl, page: page)
            } else if url.contains("?") {
                url = "\(url)&page=\(page)"
            }
        }
        let gbk = (rule.encoding ?? "utf-8").lowercased().contains("gb")
        let html = try await fetch(url, gbk: gbk)
        return parseList(html, using: lr)
    }

    /// 有些源没有单独的搜索规则，但分类页与搜索页结构一致时可用
    private func listRuleFromDetail() -> SourceRule.ListRule? {
        guard let d = rule.detail else { return nil }
        return SourceRule.ListRule(url: "", list: d.episodes, title: d.episodeTitle ?? "@text",
                                   urlRule: d.episodeUrl ?? "@href", cover: nil, artist: nil,
                                   author: nil, intro: nil, encoding: d.encoding)
    }

    func detail(for book: Book) async throws -> BookDetail {
        guard let d = rule.detail else { return BookDetail() }
        let gbk = (d.encoding ?? rule.encoding ?? "utf-8").lowercased().contains("gb")
        let desktop = (d.ua ?? rule.ua ?? "mobile").lowercased() == "desktop"
        let html = try await fetch(book.bookURL, gbk: gbk, desktop: desktop)
        let doc = HTMLParser.parse(html)
        var out = BookDetail()

        var episodes: [Episode] = []

        if let dirRule = d.dirUrl, !dirRule.isEmpty {
            // 两步：详情页 → 目录页（PTCMS 这类站点，目录页还要桌面 UA）
            let path = RuleExtractor.value(dirRule, in: [doc])
            guard !path.isEmpty else { throw SourceError.parse("详情页没找到目录入口") }
            let dirURL = path.absoluteURL(base: base)
            let dirDesktop = (d.dirUA ?? d.ua ?? rule.ua ?? "mobile").lowercased() == "desktop"
            let maxPage = d.pages?.max ?? 60
            var seen = Set<String>()
            var pageNo = 1
            while pageNo <= maxPage {
                let u: String
                if let tpl = d.pages?.url {
                    u = fill(tpl, page: pageNo, extra: ["dir": dirURL])
                } else if pageNo == 1 {
                    u = dirURL
                } else {
                    u = dirURL + (dirURL.contains("?") ? "&" : "?") + "page=\(pageNo)"
                }
                let pageHTML = try await fetch(u, gbk: gbk, desktop: dirDesktop)
                let pdoc = HTMLParser.parse(pageHTML)
                let nodes = HTMLNode.select(d.episodes, in: [pdoc])
                var added = 0
                for n in nodes {
                    let t = RuleExtractor.value(d.episodeTitle ?? "@text", in: [n])
                    var uu = RuleExtractor.value(d.episodeUrl ?? "@href", in: [n])
                    if uu.isEmpty { uu = n.attr("href") ?? "" }
                    guard !uu.isEmpty, !seen.contains(uu) else { continue }
                    seen.insert(uu)
                    episodes.append(Episode(title: t, url: uu.absoluteURL(base: base)))
                    added += 1
                }
                if added == 0 { break }
                if d.pages == nil && nodes.count < 50 { break }
                pageNo += 1
            }
        } else {
            let nodes = HTMLNode.select(d.episodes, in: [doc])
            for n in nodes {
                let t = RuleExtractor.value(d.episodeTitle ?? "@text", in: [n])
                var u = RuleExtractor.value(d.episodeUrl ?? "@href", in: [n])
                if u.isEmpty { u = n.attr("href") ?? "" }
                guard !u.isEmpty else { continue }
                episodes.append(Episode(title: t, url: u.absoluteURL(base: base)))
            }
        }

        if episodes.isEmpty { throw SourceError.parse("没解析到章节") }
        out.episodes = episodes
        if let r = d.intro { out.intro = RuleExtractor.value(r, in: [doc]) }
        if let r = d.cover { out.cover = RuleExtractor.value(r, in: [doc]).absoluteURL(base: base) }
        if let r = d.artist { out.artist = RuleExtractor.value(r, in: [doc]) }
        if let r = d.author { out.author = RuleExtractor.value(r, in: [doc]) }
        if out.cover.isEmpty { out.cover = book.cover }
        if out.intro.isEmpty { out.intro = book.intro }
        return out
    }

    func audioURL(for episode: Episode) async throws -> URL {
        guard let a = rule.audio else {
            // 没写音频规则就假设章节链接本身就是音频
            guard let u = URL(string: episode.url) else { throw SourceError.badURL(episode.url) }
            return u
        }
        let referer = (a.referer ?? "{host}/")
            .replacingOccurrences(of: "{host}", with: rule.host)
            .replacingOccurrences(of: "{episodeUrl}", with: episode.url)

        var lastError: Error = SourceError.parse("按规则没取到音频地址")
        let tries = max(1, a.retries ?? 1)
        for _ in 0..<tries {
            do {
                let raw = try await resolveAudio(a, episode: episode, referer: referer)
                if !raw.isEmpty {
                    var final = raw.absoluteURL(base: base)
                    if let prefix = a.prefix { final = prefix + raw }
                    // 地址改写（如 mp3pd 的 https 证书过期，必须换回 http）
                    for pair in a.replace ?? [] where pair.count >= 2 {
                        final = final.replacingOccurrences(of: pair[0], with: pair[1])
                    }
                    final = percentEncodedIfNeeded(final)
                    guard let url = URL(string: final) else { throw SourceError.badURL(final) }
                    return url
                }
                lastError = SourceError.parse("按规则没取到音频地址")
            } catch {
                // 状态校验没过 / 空地址 → 重试（每次都会重新拉章节页，拿到新的 token）
                lastError = error
            }
        }
        throw lastError
    }

    /// 按类型取原始地址（不含改写/编码）
    private func resolveAudio(_ a: SourceRule.AudioRule, episode: Episode, referer: String) async throws -> String {
        let desktop = (a.ua ?? rule.ua ?? "mobile").lowercased() == "desktop"

        func chapterPage() async throws -> String {
            try await fetch(episode.url, desktop: desktop)
        }

        switch a.type.lowercased() {
        case "direct":
            return episode.url

        case "regex":
            let html = try await chapterPage()
            return RuleExtractor.regex(a.pattern ?? "", in: html)
                .replacingOccurrences(of: "\\/", with: "/")

        case "json":
            let body = try await chapterPage()
            return jsonValue(body, field: a.field, alt: a.fieldAlt)

        case "redirect":
            let html = try await chapterPage()
            let u = RuleExtractor.regex(a.pattern ?? "", in: html)
            return await HTTPClient.resolveFinalURL(u.absoluteURL(base: base), referer: referer)

        case "post":
            // 1) 先拉章节页，从 <meta> 取变量（有些站限流时页面是空壳，所以整段可重试）
            let page = try await chapterPage()
            var vars: [String: String] = [:]
            for (key, metaName) in a.metaFrom ?? [:] {
                vars[key] = RuleExtractor.meta(metaName, in: page)
            }
            for (k, v) in a.metaDefaults ?? [:] where (vars[k] ?? "").isEmpty { vars[k] = v }

            func fillVars(_ t: String) -> String {
                var s = t
                for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
                return s
            }

            var bodyText = fillVars(a.body ?? "")

            // 2) 请求头（值里可写 {变量}）
            var headers: [String: String] = [:]
            for (k, v) in a.headers ?? [:] { headers[k] = fillVars(v) }
            headers["Referer"] = referer
            headers["X-Requested-With"] = headers["X-Requested-With"] ?? "XMLHttpRequest"

            // 3) 签名（塞请求头或 body 参数）
            if let sg = a.sign {
                let input = fillVars(sg.input ?? "")
                let sig = signValue(sg, input: input)
                if let h = sg.header, !h.isEmpty {
                    headers[h] = sig
                } else {
                    bodyText += (bodyText.isEmpty ? "" : "&") + "\(sg.param ?? "sp")=\(sig)"
                }
            }

            // 4) 先写需要的 cookie（有的站按 cookie 计数频控，给个随机的能避开）
            for (name, val) in a.cookies ?? [:] {
                let v = (val == "randHex16") ? randomHex(16) : fillVars(val)
                HTTPClient.setCookie(name: name, value: v, host: rule.host)
            }

            let apiURL = fill(fillVars(a.url ?? episode.url), extra: vars)
            let resp = try await HTTPClient.postForm(apiURL, body: bodyText, headers: headers,
                                                     referer: referer, mobile: !desktop)

            // 5) 状态字段校验：很多站限流时 HTTP 200 但 status 不是 200
            if let sf = a.statusField, !sf.isEmpty {
                let st = jsonValue(resp, field: sf, alt: nil)
                if let want = a.statusOK, !want.isEmpty, st != want {
                    throw SourceError.parse("接口状态 \(st.isEmpty ? "?" : st) ≠ \(want)（可能被限流）")
                }
            }
            return jsonValue(resp, field: a.field, alt: a.fieldAlt)

        default:
            return episode.url
        }
    }

    private func signValue(_ sg: SourceRule.AudioRule.Sign, input: String) -> String {
        switch sg.kind {
        case "ptcmsSp":
            let alphabet = Array(sg.alphabet ?? "PXhw7U1B0a9kQDKZsTjIASmOeNzxYG4CHo1JyRfg2b8FLpEvr3FtVnlqMidu6c")
            guard !alphabet.isEmpty else { return "" }
            var out = ""
            for ch in input {
                if let idx = alphabet.firstIndex(of: ch) {
                    out.append(alphabet[Int.random(in: 0..<alphabet.count)])
                    out.append(alphabet[(idx + 3) % alphabet.count])
                    out.append(alphabet[Int.random(in: 0..<alphabet.count)])
                } else {
                    for _ in 0..<3 { out.append(alphabet[Int.random(in: 0..<alphabet.count)]) }
                }
            }
            return out
        case "md5":
            return md5Hex(input)
        case "base64Quote":
            let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            let quoted = input.addingPercentEncoding(withAllowedCharacters: unreserved) ?? input
            return Data(quoted.utf8).base64EncodedString()
        default:
            return input
        }
    }

    private func randomHex(_ n: Int) -> String {
        (0..<n).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    /// 从 JSON 文本里按点号路径取值（先 field，取不到再 fieldAlt）
    private func jsonValue(_ text: String, field: String?, alt: String?) -> String {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return "" }
        var v = ""
        if let f = field, !f.isEmpty { v = value(at: f, in: obj) }
        if v.isEmpty, let alt, !alt.isEmpty { v = value(at: alt, in: obj) }
        return v
    }

    /// 播放时带的请求头（CDN 防盗链）
    func audioHeaders(for episode: Episode) -> [String: String] {
        guard let a = rule.audio else { return [:] }
        var h = a.headers ?? [:]
        if h["Referer"] == nil { h["Referer"] = a.referer ?? base }
        return h
    }

    func verificationURL(keyword: String) -> URL? {
        guard let v = rule.verification else { return nil }
        return URL(string: fill(v.url, kw: keyword))
    }

    private func value(at path: String, in obj: Any) -> String {
        var cur: Any? = obj
        for part in path.split(separator: ".") {
            if let dict = cur as? [String: Any] { cur = dict[String(part)] }
            else if let arr = cur as? [Any], let idx = Int(part), idx < arr.count { cur = arr[idx] }
            else { return "" }
        }
        return anyString(cur)
    }
}
