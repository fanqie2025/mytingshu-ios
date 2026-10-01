import Foundation

// MARK: - 源查找（统一走 SourceStore）

enum SourceRegistry {
    @MainActor static var all: [any BookSource] { SourceStore.shared.all }
    @MainActor static func source(withId id: String) -> (any BookSource)? {
        SourceStore.shared.all.first { $0.id == id }
    }
}

// MARK: - 书源仓库：内置（原生 + 打包的 JSON 规则）+ 用户导入

@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    /// 内置的**官方订阅地址**（我自己的书源仓库）。
    /// 界面上**不预填、不展示** —— 在「导入书源 → 订阅地址」里输入 `builtinSubscriptionKeyword` 即自动替换成它。
    static let officialSubscriptionURL =
        "https://cdn.jsdelivr.net/gh/fanqie2025/mytingshu-sources@main/subscription/sources.json"

    /// 隐藏快捷词：输入它就等于填上 `officialSubscriptionURL`（避免手打长链接）。
    /// 刻意不在界面与公开 README 里提示，只记在开发台账里。
    static let builtinSubscriptionKeyword = "666"

    /// 用户导入的 JSON 规则
    @Published private(set) var imported: [SourceRule] = []

    /// 打包在 App 里的 JSON 规则（Resources/source_*.json）
    @Published private(set) var bundled: [SourceRule] = []

    /// 内置源：**只保留「连你自己服务器」的 Audiobookshelf**。
    ///
    /// 抓站源（22听书/书音FM/酷我/爱听书/13听/乐听/恋听/29听…）一律不打包进 App，
    /// 全部通过「设置 → 导入书源」用订阅地址或粘贴 JSON 在线导入 —— App 本身只是个播放器外壳。
    let native: [any BookSource] = [
        AbsSource()
    ]

    /// 合并所有源并按 id 去重，优先级：原生源 > 订阅导入的 > 内置打包的
    /// （订阅导入的优先，才能用订阅更新源；内置的保证装完就能用）
    var all: [any BookSource] {
        var seen = Set<String>()
        var out: [any BookSource] = []
        for s in native + imported.map({ RuleSource(rule: $0) }) + bundled.map({ RuleSource(rule: $0) })
        where !seen.contains(s.id) {
            seen.insert(s.id)
            out.append(s)
        }
        return out
    }

    private var dir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sources", isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    init() { reload() }

    func reload() {
        bundled = Self.loadBundledRules()
        imported = Self.loadRules(in: dir)
    }

    // MARK: 导入

    /// 从文本导入（单个对象或数组）；返回导入的源名
    @discardableResult
    func importJSON(_ text: String) throws -> [String] {
        let rules = try Self.parseRules(text)
        guard !rules.isEmpty else { throw SourceError.parse("没有解析到任何书源") }
        var names: [String] = []
        for r in rules {
            let url = dir.appendingPathComponent("\(r.id).json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(r).write(to: url)
            names.append(r.name)
        }
        reload()
        return names
    }

    /// 从订阅地址导入（下载 JSON 再导入）
    @discardableResult
    func importURL(_ urlString: String) async throws -> [String] {
        let text = try await HTTPClient.text(urlString, allowStatus: [200])
        return try importJSON(text)
    }

    func remove(id: String) {
        let url = dir.appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(at: url)
        reload()
    }

    // MARK: 解析

    static func parseRules(_ text: String) throws -> [SourceRule] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { throw SourceError.parse("不是合法文本") }
        let dec = JSONDecoder()
        // 数组
        if trimmed.hasPrefix("[") {
            return try dec.decode([SourceRule].self, from: data)
        }
        // 单个对象
        if let one = try? dec.decode(SourceRule.self, from: data) { return [one] }
        // 订阅包裹格式：{"sources":[...]} 或 {"rules":[...]} 或 {"version":1,...}
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["sources", "rules", "list", "data"] {
                if let arr = obj[key] as? [[String: Any]],
                   let d = try? JSONSerialization.data(withJSONObject: arr),
                   let rules = try? dec.decode([SourceRule].self, from: d) {
                    return rules
                }
            }
            if let sub = obj["source"] as? [String: Any],
               let d = try? JSONSerialization.data(withJSONObject: sub),
               let rule = try? dec.decode(SourceRule.self, from: d) {
                return [rule]
            }
        }
        throw SourceError.parse("JSON 格式不认识（需要源对象、源数组，或含 sources 的订阅文件）")
    }

    private static func loadRules(in dir: URL) -> [SourceRule] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        return files.filter { $0.pathExtension.lowercased() == "json" }.compactMap { f in
            guard let d = try? Data(contentsOf: f) else { return nil }
            return try? dec.decode(SourceRule.self, from: d)
        }
    }

    /// 打包在 App 里的书源（构建时把 subscription/sources.json 复制进来），保证装完就有源可用
    private static func loadBundledRules() -> [SourceRule] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else { return [] }
        var rules: [SourceRule] = []
        for u in urls {
            guard let d = try? Data(contentsOf: u),
                  let text = String(data: d, encoding: .utf8) else { continue }
            if let parsed = try? parseRules(text) { rules.append(contentsOf: parsed) }
        }
        return rules
    }
}

// MARK: - 已启用的源

@MainActor
final class SourceSettings: ObservableObject {
    static let shared = SourceSettings()
    @Published var enabled: Set<String> { didSet { UserDefaults.standard.set(Array(enabled), forKey: key) } }
    private let key = "enabled_sources_v1"

    init() {
        if let arr = UserDefaults.standard.array(forKey: key) as? [String] {
            enabled = Set(arr)
        } else {
            enabled = Set(SourceStore.shared.all.map(\.id))
        }
    }

    /// 新导入的源默认打开
    func enableNewSources() {
        for s in SourceStore.shared.all where !enabled.contains(s.id) { enabled.insert(s.id) }
    }

    var enabledSources: [any BookSource] { SourceStore.shared.all.filter { enabled.contains($0.id) } }
}
