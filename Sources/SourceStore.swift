import Foundation

// MARK: - 书源仓库：内置（原生 + 打包的 JSON 规则）+ 用户导入

@MainActor
final class SourceStore: ObservableObject {
    static let shared = SourceStore()

    /// 用户导入的 JSON 规则
    @Published private(set) var imported: [SourceRule] = []

    /// 打包在 App 里的 JSON 规则（Resources/source_*.json）
    @Published private(set) var bundled: [SourceRule] = []

    /// 代码里写死的原生源（接口复杂、规则表达不了的）
    let native: [any BookSource] = [
        Ting22Source(),
        MekuiSource(),
        KuwoSource()
    ]

    var ruleSources: [any BookSource] { (bundled + imported).map { RuleSource(rule: $0) } }

    /// 合并所有源并按 id 去重（原生源优先，其次打包规则，最后用户导入的）
    var all: [any BookSource] {
        var seen = Set<String>()
        var out: [any BookSource] = []
        for s in native + ruleSources where !seen.contains(s.id) {
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

    private static func loadBundledRules() -> [SourceRule] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else { return [] }
        let dec = JSONDecoder()
        return urls.filter { $0.lastPathComponent.hasPrefix("source_") }.compactMap { u in
            guard let d = try? Data(contentsOf: u) else { return nil }
            return try? dec.decode(SourceRule.self, from: d)
        }
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
