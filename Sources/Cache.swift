import Foundation
import CryptoKit

// MARK: - 缓存（**只读**：App 不再下载音频，只认之前版本缓存下来的文件）
//
// 2026-10-02 按用户要求收敛：单集缓存、批量缓存、播放时自动缓存**全部移除** ——
// 连续/自动抓音频容易被源站判定为爬虫并触发风控。
// 这里保留的能力只有：认出旧缓存文件（播放时优先用本地）、统计占用、清空。
// 想恢复下载能力时，`cache(episode:source:)` 那套在 git 历史里（0.2.7 及以前）。

@MainActor
final class CacheManager: ObservableObject {
    static let shared = CacheManager()

    /// 已缓存的文件名集合
    @Published private(set) var cachedKeys: Set<String> = []

    private let fm = FileManager.default

    private init() {
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

    // 注（2026-10-02 按用户要求收敛）：这里曾有
    //   · 单集缓存 `cache(episode:source:)`
    //   · 播放时自动预取 `prefetch(book:episodes:from:count:)` + 设置项 `autoCacheNext`
    //   · 批量缓存 `cacheAll(...)` 与「删除本书缓存」
    // 全部已移除 —— 主动/自动/连续抓音频都容易招源站风控。App 现在只在线播放。
    // 需要恢复时，去 git 历史（0.2.7 及以前）取回，别凭记忆重写。
    // 现在保留的只有：`cachedKeys` / `localURL`（认出旧缓存并优先本地播放）、`sizeText()`、`clearAll()`。
}
