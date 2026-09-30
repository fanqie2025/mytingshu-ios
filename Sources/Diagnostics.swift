import Foundation
import UIKit

// MARK: - 诊断：一键测所有源 + 测订阅链接，结果可复制

@MainActor
final class Diagnostics: ObservableObject {
    struct Row: Identifiable {
        var id: String { sourceId }
        let sourceId: String
        let name: String
        let host: String
        var ok: Bool?
        var ms: Int
        var detail: String
    }

    @Published var rows: [Row] = []
    @Published var running = false
    @Published var linkResult: String?
    @Published var lastMode = "搜索测试"

    private let keyword = "三体"

    /// 只测搜索（快）
    func runAll(sources: [any BookSource]) async {
        guard !running else { return }
        running = true
        lastMode = "搜索测试"
        rows = sources.map { Row(sourceId: $0.id, name: $0.name, host: $0.host, ok: nil, ms: 0, detail: "等待…") }
        for (i, s) in sources.enumerated() {
            let t0 = Date()
            do {
                let books = try await s.search(keyword: keyword, page: 1)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                rows[i].ok = true
                rows[i].ms = ms
                rows[i].detail = books.isEmpty ? "连上了但没搜到结果" : "搜到 \(books.count) 条，如《\(books.first?.title ?? "")》"
            } catch {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                rows[i].ok = false
                rows[i].ms = ms
                rows[i].detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
        running = false
    }

    /// 深度测试：搜索 → 详情 → 第一集音频地址 → 真拉 1KB 验证是音频
    /// （跟 App 实际播放链路一致，只是不真的出声）
    func runDeep(sources: [any BookSource]) async {
        guard !running else { return }
        running = true
        lastMode = "深度测试（搜索→章节→音频试听）"
        rows = sources.map { Row(sourceId: $0.id, name: $0.name, host: $0.host, ok: nil, ms: 0, detail: "等待…") }
        for (i, s) in sources.enumerated() {
            let t0 = Date()
            var log = ""
            do {
                let books = try await withTimeout(seconds: 25) {
                    try await s.search(keyword: self.keyword, page: 1)
                }
                log += "搜索 \(books.count) 条"
                guard let b = books.first else {
                    rows[i].ok = false; rows[i].detail = log + "（没结果，后面的步骤跳过）"
                    rows[i].ms = Int(Date().timeIntervalSince(t0) * 1000); continue
                }
                let d = try await withTimeout(seconds: 45) { try await s.detail(for: b) }
                log += " · 章节 \(d.episodes.count) 集"
                guard let ep = d.episodes.first else { throw SourceError.parse("章节为空") }
                let audio = try await withTimeout(seconds: 30) { try await s.audioURL(for: ep) }
                log += " · 取到音频地址"
                let referer = s.audioHeaders(for: ep)["Referer"]
                let (playable, info) = await HTTPClient.isPlayableAudio(audio.absoluteString, referer: referer)
                log += playable ? " · 试听 \(info)" : " · 试听失败 \(info)"
                rows[i].ok = playable
                rows[i].detail = log
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                if msg.contains("验证") {
                    rows[i].ok = true
                    rows[i].detail = log + " · 需要过一次图片验证码（点搜索页底部的「去验证」）"
                } else {
                    rows[i].ok = false
                    rows[i].detail = log + " · " + msg
                }
            }
            rows[i].ms = Int(Date().timeIntervalSince(t0) * 1000)
        }
        running = false
    }

    /// 测订阅链接：能不能下载 + 能解析出几个源
    func testSubscription(_ urlString: String) async {
        linkResult = "正在测试…"
        let t0 = Date()
        do {
            let text = try await HTTPClient.text(urlString, allowStatus: [200])
            let rules = try SourceStore.parseRules(text)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            linkResult = "✅ 订阅可用：解析出 \(rules.count) 个源（\(ms)ms）\n" + rules.map { "· \($0.name)" }.joined(separator: "\n")
        } catch {
            linkResult = "❌ 订阅不可用：" + ((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func report(settings: SourceSettings, cache: CacheManager) -> String {
        var lines: [String] = []
        lines.append("【我的听书 iOS 诊断报告】")
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("App: \(v) (\(b))")
        lines.append("系统: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        lines.append("机型: \(UIDevice.current.model)")
        lines.append("已启用源: \(settings.enabledSources.count)")
        lines.append("缓存占用: \(cache.sizeText())")
        lines.append("")
        lines.append("— \(lastMode)：搜索「\(keyword)」—")
        for r in rows {
            let mark = r.ok == nil ? "…" : (r.ok! ? "✅" : "❌")
            lines.append("\(mark) \(r.name) [\(r.host)] \(r.ms)ms  \(r.detail)")
        }
        if let linkResult {
            lines.append("")
            lines.append("— 订阅链接 —")
            lines.append(linkResult)
        }
        return lines.joined(separator: "\n")
    }
}

/// 默认的订阅地址（和 README 里一致）
let defaultSubscriptionURL = "https://cdn.jsdelivr.net/gh/fanqie2025/mytingshu-ios@main/subscription/sources.json"


