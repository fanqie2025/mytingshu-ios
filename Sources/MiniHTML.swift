import Foundation

// MARK: - 极简 HTML 解析 + CSS 选择器（够采集听书站用，无第三方依赖）

final class HTMLNode {
    let tag: String
    var attrs: [String: String]
    var children: [HTMLNode] = []
    weak var parent: HTMLNode?
    var text: String = ""

    init(tag: String, attrs: [String: String] = [:], parent: HTMLNode? = nil) {
        self.tag = tag.lowercased()
        self.attrs = attrs
        self.parent = parent
    }

    /// 自身文本 + 所有后代文本
    var allText: String {
        var s = text
        for c in children { s += c.allText }
        return s
    }

    var ownText: String { text }

    func descendants() -> [HTMLNode] {
        var out: [HTMLNode] = []
        for c in children { out.append(c); out.append(contentsOf: c.descendants()) }
        return out
    }

    func attr(_ name: String) -> String? { attrs[name.lowercased()] }

    /// 简化 CSS 选择器：`tag`、`.class`、`#id`、`[attr]`、`[attr=v]`、`[attr*=v]`、后代(空格)、子代(>)
    static func select(_ selector: String, in roots: [HTMLNode]) -> [HTMLNode] {
        let parts = splitSelector(selector)
        guard !parts.isEmpty else { return [] }
        var current = roots
        for (i, part) in parts.enumerated() {
            let childOnly = part.childOfPrevious
            var next: [HTMLNode] = []
            for node in current {
                let pool = childOnly ? node.children : node.descendants()
                for cand in pool where matchesSimple(cand, part.simple) {
                    next.append(cand)
                }
            }
            // 第一段允许匹配自身
            if i == 0 {
                for r in roots where matchesSimple(r, part.simple) { next.append(r) }
            }
            current = next
        }
        // 去重（同一节点可能被多次命中）
        var seen = Set<ObjectIdentifier>()
        return current.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    struct SelectorPart {
        let simple: String
        let childOfPrevious: Bool
    }

    static func splitSelector(_ selector: String) -> [SelectorPart] {
        var parts: [SelectorPart] = []
        var buf = ""
        var child = false
        var first = true
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { parts.append(SelectorPart(simple: t, childOfPrevious: child && !first)) }
            buf = ""
            child = false
            first = false
        }
        for ch in selector {
            if ch == ">" { flush(); child = true }
            else if ch == " " || ch == "\n" || ch == "\t" { flush() }
            else { buf.append(ch) }
        }
        flush()
        return parts
    }

    static func matchesSimple(_ node: HTMLNode, _ simple: String) -> Bool {
        var s = simple.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "*" { return true }

        // 属性过滤 [attr] / [attr=v] / [attr*=v]
        var attrChecks: [(String, String?, Bool)] = [] // name, value, contains
        while let open = s.firstIndex(of: "["), let close = s[open...].firstIndex(of: "]") {
            let inside = String(s[s.index(after: open)..<close])
            if let star = inside.range(of: "*=") {
                attrChecks.append((String(inside[..<star.lowerBound]).lowercased(), String(inside[star.upperBound...]), true))
            } else if let eq = inside.firstIndex(of: "=") {
                attrChecks.append((String(inside[..<eq]).lowercased(), String(inside[inside.index(after: eq)...]), false))
            } else {
                attrChecks.append((inside.lowercased(), nil, false))
            }
            s.removeSubrange(open...close)
        }

        for (name, value, contains) in attrChecks {
            guard let v = node.attr(name) else { return false }
            if let value {
                if contains { if !v.contains(value) { return false } }
                else if v != value { return false }
            }
        }

        s = s.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return true }

        // 标签名
        if let dotOrHash = s.firstIndex(where: { $0 == "." || $0 == "#" }) {
            let tagPart = String(s[..<dotOrHash])
            if !tagPart.isEmpty && tagPart != "*" && node.tag != tagPart.lowercased() { return false }
            var rest = String(s[dotOrHash...])
            while !rest.isEmpty {
                let marker = rest.first!
                rest.removeFirst()
                let end = rest.firstIndex(where: { $0 == "." || $0 == "#" }) ?? rest.endIndex
                let name = String(rest[..<end])
                rest = String(rest[end...])
                if marker == "." {
                    let classes = (node.attr("class") ?? "").split(separator: " ").map { $0.lowercased() }
                    if !classes.contains(name.lowercased()) { return false }
                } else {
                    if node.attr("id")?.lowercased() != name.lowercased() { return false }
                }
            }
            return true
        }
        return node.tag == s.lowercased()
    }
}

/// 容错 HTML 解析器：不追求标准，只求把常见网页拆成树
enum HTMLParser {
    private static let voidTags: Set<String> = ["img", "br", "hr", "meta", "link", "input", "source", "area", "base", "col", "embed", "param", "track", "wbr"]

    static func parse(_ html: String) -> HTMLNode {
        let root = HTMLNode(tag: "root")
        var stack: [HTMLNode] = [root]
        var i = html.startIndex

        while i < html.endIndex {
            guard let lt = html[i...].firstIndex(of: "<") else {
                appendText(String(html[i...]), to: stack.last)
                break
            }
            if lt > i { appendText(String(html[i..<lt]), to: stack.last) }

            // 注释 / CDATA / doctype
            if html[lt...].hasPrefix("<!--") {
                if let end = html.range(of: "-->", range: lt..<html.endIndex) {
                    i = end.upperBound
                    continue
                } else { break }
            }
            if html[lt...].hasPrefix("<!") {
                if let end = html[lt...].firstIndex(of: ">") { i = html.index(after: end); continue } else { break }
            }
            guard let gt = html[lt...].firstIndex(of: ">") else {
                appendText(String(html[lt...]), to: stack.last)
                break
            }
            let inside = String(html[html.index(after: lt)..<gt])
            i = html.index(after: gt)

            if inside.hasPrefix("/") {
                let name = inside.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                if let idx = stack.lastIndex(where: { $0.tag == name }), idx > 0 {
                    stack.removeSubrange(idx..<stack.count)
                }
                continue
            }

            let selfClosing = inside.hasSuffix("/")
            let body = selfClosing ? String(inside.dropLast()) : inside
            let (tag, attrs) = parseTag(body)
            guard !tag.isEmpty else { continue }
            let node = HTMLNode(tag: tag, attrs: attrs, parent: stack.last)
            stack.last?.children.append(node)
            if !selfClosing && !voidTags.contains(tag.lowercased()) {
                stack.append(node)
            }
        }
        return root
    }

    private static func appendText(_ s: String, to node: HTMLNode?) {
        guard let node, !s.isEmpty else { return }
        // script/style 内容丢掉
        if node.tag == "script" || node.tag == "style" { return }
        node.text += s
    }

    private static func parseTag(_ body: String) -> (String, [String: String]) {
        var s = Substring(body)
        var tag = ""
        while let c = s.first, !c.isWhitespace { tag.append(c); s = s.dropFirst() }
        var attrs: [String: String] = [:]
        while !s.isEmpty {
            while let c = s.first, c.isWhitespace { s = s.dropFirst() }
            if s.isEmpty { break }
            var name = ""
            while let c = s.first, c != "=", !c.isWhitespace { name.append(c); s = s.dropFirst() }
            while let c = s.first, c.isWhitespace { s = s.dropFirst() }
            var value = ""
            if s.first == "=" {
                s = s.dropFirst()
                while let c = s.first, c.isWhitespace { s = s.dropFirst() }
                if s.first == "\"" || s.first == "'" {
                    let quote = s.first!
                    s = s.dropFirst()
                    while let c = s.first, c != quote { value.append(c); s = s.dropFirst() }
                    if s.first == quote { s = s.dropFirst() }
                } else {
                    while let c = s.first, !c.isWhitespace { value.append(c); s = s.dropFirst() }
                }
            }
            if !name.isEmpty { attrs[name.lowercased()] = value }
        }
        return (tag, attrs)
    }
}

// MARK: - 规则取值："selector@text" / "@href" / "@src" / "selector@attr(name)"

enum RuleExtractor {
    /// 在节点集合里按规则取值；rule 形如 `h2 a.f-bold@text`、`img@src`、`@href`、`@text`、`@html`
    static func value(_ rule: String, in nodes: [HTMLNode], htmlCache: String? = nil) -> String {
        let parts = rule.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        var selector = parts.count > 0 ? String(parts[0]).trimmingCharacters(in: .whitespaces) : ""
        let accessor = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "text"

        var roots = nodes
        // `^li img@src`：先往上找到最近的 li 再找图（封面常和条目容器不在同一层）
        if selector.hasPrefix("^") {
            let rest = selector.dropFirst()
            let tagEnd = rest.firstIndex(where: { $0 == " " }) ?? rest.endIndex
            let upTag = String(rest[rest.startIndex..<tagEnd]).lowercased()
            let remain = tagEnd < rest.endIndex ? String(rest[rest.index(after: tagEnd)...]) : ""
            var climbed: [HTMLNode] = []
            for n in nodes {
                var cur: HTMLNode? = n
                while let c = cur, c.tag != upTag { cur = c.parent }
                if let c = cur { climbed.append(c) }
            }
            if !climbed.isEmpty {
                roots = climbed
                selector = remain
            }
        }

        var pool = roots
        if !selector.isEmpty {
            pool = HTMLNode.select(selector, in: roots)
        }
        guard let node = pool.first else { return "" }

        if accessor == "text" { return node.allText.htmlDecoded.strippedTags }
        if accessor == "ownText" { return node.ownText.htmlDecoded.strippedTags }
        if accessor == "html" { return node.allText.htmlDecoded }
        if accessor.hasPrefix("attr(") {
            let name = accessor.dropFirst(5).dropLast()
            return (node.attr(String(name)) ?? "").htmlDecoded
        }
        // @regex(模式) 或 @regex(模式,2)：在节点文本上跑正则
        if accessor.hasPrefix("regex(") {
            let inner = String(accessor.dropFirst(6).dropLast())
            var pattern = inner
            var group = 1
            if let comma = inner.lastIndex(of: ","), let g = Int(inner[inner.index(after: comma)...].trimmingCharacters(in: .whitespaces)) {
                group = g
                pattern = String(inner[..<comma])
            }
            return node.allText.firstMatch(pattern, group: group) ?? ""
        }
        // @href / @src / @title ... 直接当属性名
        return (node.attr(accessor) ?? "").htmlDecoded
    }

    /// 读 <meta name="x" content="y">
    static func meta(_ name: String, in html: String) -> String {
        html.firstMatch("<meta[^>]+name=\"\(name)\"[^>]*content=\"([^\"]*)\"") ??
        html.firstMatch("<meta[^>]+content=\"([^\"]*)\"[^>]*name=\"\(name)\"") ?? ""
    }

    /// 用整页 HTML 跑正则取第一个分组
    static func regex(_ pattern: String, in html: String, group: Int = 1) -> String {
        html.firstMatch(pattern, group: group) ?? ""
    }
}
