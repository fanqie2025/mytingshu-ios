import Foundation

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
        if !gbk, let s = String(data: data, encoding: .utf8) { return s }
        let cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        if let s = String(data: data, encoding: enc) { return s }
        return String(data: data, encoding: .utf8) ?? ""
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

/// 任意 JSON 值 → String（数字/布尔也能转）
func anyString(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case .none: return ""
    case .some(let other): return "\(other)"
    }
}

/// 清洗接口返回的富文本（去标签 + 还原实体）
func cleanText(_ v: Any?) -> String {
    anyString(v).htmlDecoded.strippedTags
}
