import Foundation

// MARK: - JSON 书源规则（导入书源用）

/// 一个可导入的书源定义。字段都可选，按需填。
struct SourceRule: Codable, Identifiable {
    var id: String
    var name: String
    var host: String
    var desc: String?
    var encoding: String?          // "utf-8"（默认）或 "gbk"
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
        var url: String                    // 支持 {kw} {page} {host}
        var list: String                   // 条目容器选择器
        var title: String                  // 取值规则，如 "h2 a@text"
        var urlRule: String?               // 条目链接取值，如 "h2 a@href"（默认同 title 的 @href）
        var cover: String?
        var artist: String?
        var author: String?
        var intro: String?
        var encoding: String?
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
    }

    struct AudioRule: Codable {
        var type: String                   // regex | direct | json | redirect
        var pattern: String?               // regex 用
        var field: String?                 // json 用（点号路径）
        var prefix: String?                // 相对地址前缀
        var referer: String?
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

    private func fetch(_ url: String, gbk: Bool = false) async throws -> String {
        var headers = rule.headers ?? [:]
        if headers["Referer"] == nil { headers["Referer"] = base }
        return try await HTTPClient.text(url, gbk: gbk, headers: headers, referer: base)
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
        let html = try await fetch(url, gbk: gbk)
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
            url = url.contains("?") ? "\(url)&page=\(page)" : url
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
        let gbk = (rule.detail?.encoding ?? rule.encoding ?? "utf-8").lowercased().contains("gb")
        let html = try await fetch(book.bookURL, gbk: gbk)
        let doc = HTMLParser.parse(html)
        var out = BookDetail()
        guard let d = rule.detail else { return out }
        let nodes = HTMLNode.select(d.episodes, in: [doc])
        var episodes: [Episode] = []
        for n in nodes {
            let t = RuleExtractor.value(d.episodeTitle ?? "@text", in: [n])
            var u = RuleExtractor.value(d.episodeUrl ?? "@href", in: [n])
            if u.isEmpty { u = n.attr("href") ?? "" }
            guard !u.isEmpty else { continue }
            episodes.append(Episode(title: t, url: u.absoluteURL(base: base)))
        }
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
        let referer = a.referer ?? base
        var raw = ""
        switch a.type {
        case "direct":
            raw = episode.url
        case "regex":
            let html = try await fetch(episode.url)
            raw = RuleExtractor.regex(a.pattern ?? "", in: html)
        case "json":
            let body = try await fetch(episode.url)
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                raw = value(at: a.field ?? "", in: obj)
            }
        case "redirect":
            if let p = a.pattern {
                let html = try await fetch(episode.url)
                let u = RuleExtractor.regex(p, in: html)
                raw = await HTTPClient.resolveFinalURL(u.absoluteURL(base: base), referer: referer)
            }
        default:
            raw = episode.url
        }
        if raw.isEmpty { throw SourceError.parse("按规则没取到音频地址") }
        var final = raw.absoluteURL(base: base)
        if let prefix = a.prefix { final = prefix + raw }
        guard let url = URL(string: final) else { throw SourceError.badURL(final) }
        return url
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
