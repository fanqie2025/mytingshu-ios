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

    private let keyword = "三体"

    func runAll(sources: [any BookSource]) async {
        guard !running else { return }
        running = true
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
        lines.append("— 搜索「\(keyword)」结果 —")
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
