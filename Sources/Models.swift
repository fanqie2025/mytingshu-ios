import Foundation

// MARK: - 数据模型

struct Book: Identifiable, Hashable, Codable {
    var id: String { bookURL }
    let sourceId: String
    let title: String
    var author: String = ""
    var artist: String = ""
    var cover: String = ""
    let bookURL: String
    var intro: String = ""
}

struct Episode: Identifiable, Hashable, Codable {
    var id: String { url }
    let title: String
    let url: String
}

struct BookDetail {
    var episodes: [Episode] = []
    var intro: String = ""
    var artist: String = ""
    var author: String = ""
    var cover: String = ""
}

struct SourceCategory: Identifiable, Hashable {
    var id: String { url }
    let title: String
    let url: String
}

struct CategoryMenu: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let categories: [SourceCategory]
}

// MARK: - 源协议

/// 一个听书源。所有方法都是 async，网络请求自己负责加 UA / Referer / Cookie。
protocol BookSource: AnyObject, Identifiable {
    /// 源唯一 ID（32 位 hex，与安卓端保持一致，方便对照）
    var id: String { get }
    var name: String { get }
    /// 站点主页，用于展示与去重
    var host: String { get }
    var desc: String { get }
    var searchable: Bool { get }
    var discoverable: Bool { get }
    /// 搜索是否需要先过一次验证码（如 22听书）
    var needsVerification: Bool { get }

    func search(keyword: String, page: Int) async throws -> [Book]
    func menus() async throws -> [CategoryMenu]
    func books(in category: SourceCategory, page: Int) async throws -> [Book]
    func detail(for book: Book) async throws -> BookDetail
    func audioURL(for episode: Episode) async throws -> URL

    /// 播放这个源的音频时需要的额外请求头（不少站的 CDN 有 Referer 防盗链）
    func audioHeaders(for episode: Episode) -> [String: String]

    /// 需要验证时的验证页地址
    func verificationURL(keyword: String) -> URL?
}

extension BookSource {
    var searchable: Bool { true }
    var discoverable: Bool { true }
    var needsVerification: Bool { false }
    var desc: String { "" }
    func menus() async throws -> [CategoryMenu] { [] }
    func books(in category: SourceCategory, page: Int) async throws -> [Book] { [] }
    func audioHeaders(for episode: Episode) -> [String: String] { [:] }
    func verificationURL(keyword: String) -> URL? { nil }
}

// MARK: - 错误

enum SourceError: LocalizedError {
    case badURL(String)
    case http(Int, String)
    case parse(String)
    case needVerification
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "链接无效：\(s)"
        case .http(let code, let u): return "HTTP \(code)：\(u)"
        case .parse(let s): return "解析失败：\(s)"
        case .needVerification: return "需要先过一次验证码"
        case .message(let s): return s
        }
    }
}
