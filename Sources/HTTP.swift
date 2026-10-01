import Foundation
import CryptoKit

// MARK: - 网络

enum HTTPClient {
    /// 手机版 UA（与安卓端一致，多数源站对手机 UA 更友好）
    static let mobileUA = "Mozilla/5.0 (Linux; Android 9; SM-S9280) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.114 Mobile Safari/537.36"
    static let desktopUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    static func request(_ urlString: String,
                        headers: [String: String] = [:],
                        referer: String? = nil,
                        mobile: Bool = true,
                        timeout: TimeInterval = 20) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw SourceError.badURL(urlString) }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue(mobile ? mobileUA : desktopUA, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        return req
    }

    @discardableResult
    static func data(_ urlString: String,
                     headers: [String: String] = [:],
                     referer: String? = nil,
                     mobile: Bool = true,
                     timeout: TimeInterval = 20) async throws -> (Data, HTTPURLResponse) {
        let req = try request(urlString, headers: headers, referer: referer, mobile: mobile, timeout: timeout)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SourceError.message("无 HTTP 响应") }
        return (data, http)
    }

    /// 取文本；isGBK=true 时用 GB18030 解码（中文老站常见）
    static func text(_ urlString: String,
                     gbk: Bool = false,
                     headers: [String: String] = [:],
                     referer: String? = nil,
                     mobile: Bool = true,
                     allowStatus: Set<Int> = [200]) async throws -> String {
        let (data, http) = try await data(urlString, headers: headers, referer: referer, mobile: mobile)
        if !allowStatus.contains(http.statusCode) {
            throw SourceError.http(http.statusCode, urlString)
        }
        return decode(data, gbk: gbk)
    }

    /// POST 表单（application/x-www-form-urlencoded），返回文本
    static func postForm(_ urlString: String,
                         body: String,
                         headers: [String: String] = [:],
                         referer: String? = nil,
                         gbk: Bool = false,
                         mobile: Bool = false) async throws -> String {
        var req = try request(urlString, headers: headers, referer: referer, mobile: mobile)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = body.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SourceError.message("无 HTTP 响应") }
        guard http.statusCode == 200 else { throw SourceError.http(http.statusCode, urlString) }
        return decode(data, gbk: gbk)
    }

    /// POST JSON（有些站要 application/json + X-Requested-With）
    static func postJSON(_ urlString: String,
                         json: String,
                         headers: [String: String] = [:],
                         referer: String? = nil,
                         mobile: Bool = true) async throws -> String {
        var req = try request(urlString, headers: headers, referer: referer, mobile: mobile)
        req.httpMethod = "POST"
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.httpBody = json.data(using: .utf8)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw SourceError.message("无 HTTP 响应") }
        guard http.statusCode == 200 else { throw SourceError.http(http.statusCode, urlString) }
        return decode(data)
    }

    /// 解「反转 + base64」型 JS Cookie 挑战，返回该写的**全部** cookie。
    ///
    /// 站点有两种写法，只写一个 cookie 会一直停在挑战页（「能搜索、进不去」的根因）：
    ///   A) `document.cookie = '__51guid__=' + encodeURIComponent(token) + '; ' + config;`（PTCMS：爱听书/13听书网）
    ///   B) `var mainCookie = 'pt_guid=' + encodeURIComponent(token) + '; ' + config;` → `document.cookie = mainCookie;`（乐听网/29听书网）
    ///   C) `document.cookie = 'name=value; path=/';`
    static func solveGuardCookies(_ html: String) -> [(String, String)] {
        guard let raw = html.firstMatch(#"var\s+reversed\s*=\s*"([^"]+)""#) else { return [] }
        let forward = String(raw.reversed())
        let padded = forward + String(repeating: "=", count: (4 - forward.count % 4) % 4)
        guard let data = Data(base64Encoded: padded, options: .ignoreUnknownCharacters),
              let js = String(data: data, encoding: .utf8) else { return [] }

        // var X = '...'
        let vNames = js.allMatches(#"var\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'"#)
        let vValues = js.allMatches(#"var\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*'([^']*)'"#)
        var vars: [String: String] = [:]
        for (i, n) in vNames.enumerated() where i < vValues.count { vars[n] = vValues[i] }

        // 形态 B 的中间变量：lhs = '<cookieName>=' + [encodeURIComponent(](var)
        let expr = #"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([A-Za-z_][A-Za-z0-9_]*)='\s*\+\s*(?:encodeURIComponent\()?([A-Za-z_][A-Za-z0-9_]*)\)?"#
        let lhsList = js.allMatches(expr, group: 1)
        let cnameList = js.allMatches(expr, group: 2)
        let rvarList = js.allMatches(expr, group: 3)
        var viaVar: [String: (String, String)] = [:]
        for (i, l) in lhsList.enumerated() where i < cnameList.count && i < rvarList.count {
            viaVar[l] = (cnameList[i], vars[rvarList[i]] ?? "")
        }

        var cookies: [String: String] = [:]
        for rawExpr in js.allMatches(#"document\.cookie\s*=\s*([^;\n]+)"#) {
            let e = rawExpr.trimmingCharacters(in: .whitespacesAndNewlines)
            // A) 直接拼接字符串
            let direct = #"^'([A-Za-z_][A-Za-z0-9_]*)='\s*\+\s*(?:encodeURIComponent\()?([A-Za-z_][A-Za-z0-9_]*)\)?"#
            if let n = e.firstMatch(direct, group: 1), let vn = e.firstMatch(direct, group: 2) {
                cookies[n] = vars[vn] ?? ""
                continue
            }
            // C) 纯字面量 'name=value'
            let literal = #"^'([A-Za-z_][A-Za-z0-9_]*)=([^;']*)"#
            if let n = e.firstMatch(literal, group: 1), let v = e.firstMatch(literal, group: 2) {
                cookies[n] = v
                continue
            }
            // B) 引用中间变量
            if let ref = e.firstMatch(#"^([A-Za-z_][A-Za-z0-9_]*)$"#), let pair = viaVar[ref] {
                cookies[pair.0] = pair.1
            }
        }
        return cookies.map { ($0.key, $0.value) }
    }

    /// 把守卫要求的 cookie 全写进共享存储
    static func applyGuardCookies(_ cookies: [(String, String)], host: String) {
        for (name, value) in cookies where !name.isEmpty {
            setCookie(name: name, value: value, host: host)
        }
    }

    /// 兼容旧调用：只取某一个 cookie 的值
    static func solveGuardToken(_ html: String, cookieName: String) -> String? {
        solveGuardCookies(html).first { $0.0 == cookieName }?.1
    }

    /// 写一个 cookie 到共享存储（供后续请求带上）
    static func setCookie(name: String, value: String, host: String) {
        guard let h = URL(string: host)?.host else { return }
        let props: [HTTPCookiePropertyKey: Any] = [.domain: h, .path: "/", .name: name, .value: value]
        if let c = HTTPCookie(properties: props) { HTTPCookieStorage.shared.setCookie(c) }
    }

    /// 跟随 302 取最终 URL
    static func resolveFinalURL(_ urlString: String, referer: String? = nil, mobile: Bool = true) async -> String {
        guard let url = URL(string: urlString) else { return urlString }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.setValue(mobile ? mobileUA : desktopUA, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if let (_, resp) = try? await session.data(for: req), let final = resp.url?.absoluteString, !final.isEmpty {
            return final
        }
        return urlString
    }

    /// 判断直链是不是音频（取前 1KB 看状态码与 Content-Type）
    static func isPlayableAudio(_ urlString: String, referer: String? = nil) async -> (Bool, String) {
        guard let url = URL(string: urlString) else { return (false, "链接无效") }
        var req = URLRequest(url: url)
        req.setValue("bytes=0-1024", forHTTPHeaderField: "Range")
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        guard let (data, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse else {
            return (false, "请求失败")
        }
        let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ok = [200, 206].contains(http.statusCode) &&
            (ct.contains("audio") || ct.contains("mpeg") || ct.contains("m4a") || ct.contains("octet-stream") || data.starts(with: [0x49, 0x44, 0x33]))
        return (ok, "HTTP \(http.statusCode) \(ct)")
    }

    // MARK: 解码

    static func decode(_ data: Data, gbk: Bool = false) -> String {
        // 有些接口（如 ting15 的播放接口）返回带 UTF-8 BOM，JSON 解析会被它搞挂，统一剥掉
        var d = data
        if d.count >= 3 && d[0] == 0xEF && d[1] == 0xBB && d[2] == 0xBF { d = d.subdata(in: 3..<d.count) }
        if !gbk, let s = String(data: d, encoding: .utf8) { return s }
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        if let s = String(data: d, encoding: enc) { return s }
        return String(data: d, encoding: .utf8) ?? ""
    }

    // MARK: Cookie（供 WKWebView 验证码流程注入）

    static func injectCookies(from store: [HTTPCookie]) {
        for c in store { HTTPCookieStorage.shared.setCookie(c) }
    }

    static func cookieHeader(for urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let cookies = HTTPCookieStorage.shared.cookies(for: url), !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: - HTML 小工具（无第三方依赖，正则抽取）

extension String {
    func firstMatch(_ pattern: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return nil }
        let range = NSRange(startIndex..<endIndex, in: self)
        guard let m = re.firstMatch(in: self, options: [], range: range), m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: self) else { return nil }
        return String(self[r])
    }

    func allMatches(_ pattern: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let range = NSRange(startIndex..<endIndex, in: self)
        return re.matches(in: self, options: [], range: range).compactMap { m in
            guard m.numberOfRanges > group, let r = Range(m.range(at: group), in: self) else { return nil }
            return String(self[r])
        }
    }

    var htmlDecoded: String {
        var s = self
        let map = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                   "&lt;": "<", "&gt;": ">", "&ldquo;": "“", "&rdquo;": "”", "&hellip;": "…"]
        for (k, v) in map { s = s.replacingOccurrences(of: k, with: v) }
        // 数字实体
        if let re = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let matches = re.matches(in: s, options: [], range: NSRange(s.startIndex..<s.endIndex, in: s)).reversed()
            for m in matches {
                guard let r = Range(m.range(at: 1), in: s), let code = UInt32(s[r]), let scalar = Unicode.Scalar(code) else { continue }
                if let full = Range(m.range(at: 0), in: s) { s.replaceSubrange(full, with: String(Character(scalar))) }
            }
        }
        return s
    }

    var strippedTags: String {
        replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func absoluteURL(base: String) -> String {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("http") { return s }
        if s.hasPrefix("//") { return "https:" + s }
        if s.hasPrefix("/") { return base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + s }
        return base + s
    }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

/// 给任意 async 操作套一个超时（避免某个源卡住拖垮整体）
func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SourceError.message("超时（\(Int(seconds)) 秒没有响应）")
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw SourceError.message("没有结果")
        }
        return first
    }
}

/// MD5（书源规则里的 md5 签名用；iOS 15+ 用 CryptoKit）
func md5Hex(_ s: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// 任意 JSON 值 → String（数字/布尔也能转）
func anyString(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case .none: return ""
    case .some(let other): return "\(other)"
    }
}

/// 去掉 UTF-8 BOM —— 有听网的音频接口返回就带 BOM，JSONSerialization 会直接失败
func stripBOM(_ s: String) -> String {
    var t = s
    while let f = t.unicodeScalars.first, f.value == 0xFEFF { t.removeFirst() }
    return t
}

/// 清洗接口返回的富文本（去标签 + 还原实体 + 再解一层 \uXXXX）
/// 酷我 ft=music 的 ARTIST 是双重转义后的 `三体宇宙\u0026喜马拉雅`，单靠 htmlDecoded 解不掉
func cleanText(_ v: Any?) -> String {
    var s = anyString(v).htmlDecoded.strippedTags
    s = s.replacingOccurrences(of: "\\u0026", with: "&")
    s = s.replacingOccurrences(of: "\\u002F", with: "/")
    s = s.replacingOccurrences(of: "\\/", with: "/")
    // 其余 \uXXXX 统一解码（顺手清掉多余的转义反斜杠）
    if s.contains("\\u") {
        var out = ""
        var chars = Array(s)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 5 < chars.count, chars[i + 1] == "u",
               let code = UInt32(String(chars[(i + 2)...(i + 5)]), radix: 16),
               let scalar = Unicode.Scalar(code) {
                out.append(Character(scalar))
                i += 6
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        s = out
    }
    s = s.replacingOccurrences(of: "\\&", with: "&")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 把「单引号 JS/Python 对象字面量」归一化成 JSON（酷我接口 `rformat=json` 名不副实）
func normalizeLiteral(_ text: String) -> String {
    var out = ""
    let chars = Array(text)
    var i = 0
    let n = chars.count
    func isIdent(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }
    while i < n {
        let ch = chars[i]
        if ch == "'" || ch == "\"" {
            let quote = ch
            i += 1
            var buf = ""
            while i < n {
                let c = chars[i]
                if c == "\\", i + 1 < n {
                    buf.append(c); buf.append(chars[i + 1]); i += 2; continue
                }
                if c == quote { i += 1; break }
                buf.append(c); i += 1
            }
            // 单引号串里的双引号要转义
            buf = buf.replacingOccurrences(of: "\\\"", with: "\"")
                     .replacingOccurrences(of: "\"", with: "\\\"")
            out += "\"" + buf + "\""
            continue
        }
        if ch.isLetter || ch == "_" {
            var j = i
            while j < n, isIdent(chars[j]) { j += 1 }
            let word = String(chars[i..<j])
            var k = j
            while k < n, chars[k] == " " || chars[k] == "\t" || chars[k] == "\r" || chars[k] == "\n" { k += 1 }
            if k < n, chars[k] == ":" {
                out += "\"" + word + "\""
            } else {
                out += word
            }
            i = j
            continue
        }
        out += String(ch)
        i += 1
    }
    // 尾逗号
    if let re = try? NSRegularExpression(pattern: ",(\\s*[\\]}])") {
        let range = NSRange(out.startIndex..<out.endIndex, in: out)
        out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "$1")
    }
    return out
}

/// 字面量文本 → JSON 对象（先归一化；失败返回 nil）
func parseLiteralObject(_ text: String) -> Any? {
    let body = stripBOM(text)
    if let d = body.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return o }
    let norm = normalizeLiteral(body)
    if let d = norm.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) { return o }
    return nil
}

/// 非 ASCII 的 URL 才需要百分号编码。
/// 已经是百分号编码的（纯 ASCII）必须原样返回 —— 否则 % 会被二次编码成 %25，CDN 直接 404。
func percentEncodedIfNeeded(_ s: String) -> String {
    if s.allSatisfy({ $0.isASCII }) { return s }
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~:/?#[]@!$&'()*+,;=%")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

