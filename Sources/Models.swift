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

/// 一页目录（懒加载用）。
/// 大长篇的源（13听书网这类 50 集/页、2600 集 = 52 页）一次拉全既要等几十秒，
/// 又会因为高频请求被源站 429 —— 所以改成「滑到底再拉下一页」。
struct EpisodePage {
    var episodes: [Episode] = []
    /// 只有第一页带书籍元信息（简介 / 封面 / 播音）
    var detail: BookDetail = BookDetail()
    /// 下一页的页码（1-based）；nil = 没有更多了
    var nextPage: Int?
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
    /// 增量拉目录：从第 `page` 页（1-based）开始最多拉 `pages` 页。
    /// 默认实现退化成一次性 `detail(for:)`（Audiobookshelf 这类一次给全的源不用改）。
    func episodePage(for book: Book, page: Int, pages: Int) async throws -> EpisodePage
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
    /// 默认：只有第一页有内容、一次给全（`nextPage = nil`）
    func episodePage(for book: Book, page: Int, pages: Int) async throws -> EpisodePage {
        guard page <= 1 else { return EpisodePage() }
        let detail = try await self.detail(for: book)
        return EpisodePage(episodes: detail.episodes, detail: detail, nextPage: nil)
    }
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
