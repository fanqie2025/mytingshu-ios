import Foundation
import CryptoKit

// MARK: - 缓存（把整集音频下到本地，播放优先用本地文件，并可自动预取下一集）

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    /// 已缓存的文件名集合
    @Published private(set) var cachedKeys: Set<String> = []
    /// 正在下载
    @Published private(set) var downloadingKeys: Set<String> = []
    /// 播放时自动预取后面几集（0 = 关闭）
    @Published var autoCacheNext: Int {
        didSet { UserDefaults.standard.set(autoCacheNext, forKey: "auto_cache_next_v1") }
    }

    private let fm = FileManager.default

    private init() {
        // 默认**不**自动缓存：自动下载会抢带宽、让起播变慢；用户可在设置里自己开
        autoCacheNext = UserDefaults.standard.object(forKey: "auto_cache_next_v1") as? Int ?? 0
        refresh()
    }

    var dir: URL {
        let d = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("audio_cache", isDirectory: true)
        if !fm.fileExists(atPath: d.path) {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    /// 用章节地址算稳定文件名（Swift 的 hashValue 每次启动都变，不能用）
    func key(_ episodeURL: String) -> String {
        let hex = SHA256.hash(data: Data(episodeURL.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(32)) + ".audio"
    }

    func isCached(_ episodeURL: String) -> Bool { cachedKeys.contains(key(episodeURL)) }
    func isDownloading(_ episodeURL: String) -> Bool { downloadingKeys.contains(key(episodeURL)) }

    func localURL(for episodeURL: String) -> URL? {
        let f = dir.appendingPathComponent(key(episodeURL))
        return fm.fileExists(atPath: f.path) ? f : nil
    }

    func refresh() {
        cachedKeys = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
    }

    func cacheSize() -> Int64 {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(Int64(0)) { sum, f in
            sum + Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    func sizeText() -> String {
        let b = cacheSize()
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(b) / 1024 / 1024) }
        return String(format: "%.2f GB", Double(b) / 1024 / 1024 / 1024)
    }

    func clearAll() {
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? fm.removeItem(at: f) }
        refresh()
    }

    /// 下载一集到本地（失败不影响在线播放）。
    /// 返回「这一集现在是否在缓存里」：原本就有 / 已在下载中 / 下载成功 → `true`。
    @discardableResult
    func cache(episode: Episode, source: any BookSource) async -> Bool {
        let k = key(episode.url)
        if cachedKeys.contains(k) { return true }
        if downloadingKeys.contains(k) { return true }   // 已在飞：交给那一趟，不重复下载
        downloadingKeys.insert(k)
        defer { downloadingKeys.remove(k) }
        do {
            let remote = try await source.audioURL(for: episode)
            var req = URLRequest(url: remote)
            req.setValue(HTTPClient.mobileUA, forHTTPHeaderField: "User-Agent")
            for (hk, hv) in source.audioHeaders(for: episode) {
                req.setValue(hv, forHTTPHeaderField: hk)
            }
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            if let http = resp as? HTTPURLResponse, !(http.statusCode == 200 || http.statusCode == 206) { return false }
            let dest = dir.appendingPathComponent(k)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            cachedKeys.insert(k)
            objectWillChange.send()
            return true
        } catch {
            // 静默失败：缓存只是锦上添花（调用方拿返回值判断成败）
            return false
        }
    }

    /// 播放时自动预取后面 count 集（0–3 集，天然是低频的，不需要额外限速）
    func prefetch(book: Book, episodes: [Episode], from index: Int, count: Int) async {
        guard count > 0, index + 1 < episodes.count else { return }
        guard let src = SourceStore.shared.all.first(where: { $0.id == book.sourceId }) else { return }
        for i in (index + 1)..<min(episodes.count, index + 1 + count) {
            await cache(episode: episodes[i], source: src)
        }
    }

    // 注：这里曾有「批量缓存」（cacheAll + 限量限速 + 取消 + 进度）与「删除本书缓存」，
    // 已按用户要求移除 —— 连续拉多个音频最容易招源站风控。
    // 保留的缓存能力：单集缓存 `cache(episode:source:)`（和"点开这一集播放"同量级）、
    // 播放时预取 `prefetch`（0–3 集，默认关）、`clearAll()` 全清。
}
