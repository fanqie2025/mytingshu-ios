import SwiftUI

// MARK: - 缓存管理页（设计：Bounded 第二版，2026-10-02）
//
// 之前缓存设置埋在「我的 → 源管理与设置」里还要滚动才能看到；这页把这件事单独拿出来。
// 关键约束（写在这里也写在界面上，不藏在代码里）：
//   批量缓存**一次最多 10 集、每集约 5 秒**（±1 秒抖动）—— 连续抓取会触发源站风控。
//   `CacheManager.batchLimit` / `batchIntervalSec` 是保险丝，不是性能参数。

struct CacheView: View {
    @ObservedObject private var cache = CacheManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overviewCard
                    autoCacheCard
                    ruleCard
                    dangerCard
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Theme.bg)
            .toolbar(.visible, for: .navigationBar)
            .navigationTitle("缓存管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .font(Theme.meta)
                        .tint(Theme.accent)
                }
            }
            .overlay {
                if showClearConfirm {
                    ConfirmDialog(
                        isPresented: $showClearConfirm,
                        title: "清空全部缓存",
                        items: [
                            "会删掉已下载的全部音频（当前 \(cache.cachedKeys.count) 集 / \(cache.sizeText())）",
                            "不影响已收藏的书与收听进度，下次播放会重新联网取"
                        ],
                        confirmTitle: "确认清空",
                        onConfirm: { cache.clearAll() }
                    )
                }
            }
        }
    }

    // MARK: 概览

    private var overviewCard: some View {
        HStack(spacing: 0) {
            stat(value: cache.sizeText(), label: "已缓存占用")
            separator
            stat(value: "\(cache.cachedKeys.count)", label: "已缓存集数")
            if !cache.downloadingKeys.isEmpty {
                separator
                stat(value: "\(cache.downloadingKeys.count)", label: "正在下载")
            }
        }
        .padding(.vertical, 18)
        .background(cardBackground)
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Theme.statNumber)
                .foregroundColor(Theme.text1)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(label)
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
        }
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1, height: 30)
    }

    // MARK: 自动缓存

    private var autoCacheCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("播放时自动缓存后面的集")
                .font(Theme.meta)
                .foregroundColor(Theme.text1)

            Picker("自动缓存下集", selection: Binding(
                get: { cache.autoCacheNext },
                set: { cache.autoCacheNext = $0 })) {
                Text("关闭").tag(0)
                Text("1 集").tag(1)
                Text("2 集").tag(2)
                Text("3 集").tag(3)
            }
            .pickerStyle(.segmented)

            Text("这是「下一集也存好」，听的时候不用等网；关闭后只有你手动点过的集才会缓存。")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: 批量缓存的规则（刻意不可调）

    private var ruleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("批量缓存的限制", systemImage: "exclamationmark.triangle")
                .font(Theme.meta)
                .foregroundColor(Theme.gold)

            Text("一次最多 \(CacheManager.batchLimit) 集，每集之间等 \(Int(CacheManager.batchIntervalSec)) 秒左右（带随机抖动）。")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text1)

            Text("这条限制是故意的：连续、快速地抓音频会被源站判定为爬虫并触发风控（限流、换 UA、甚至封 IP）。所以批量缓存只给「接下来 N 集」，不做整本缓存，也不提供调快的开关。")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: 危险区

    private var dangerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showClearConfirm = true
            } label: {
                Label("清空全部缓存", systemImage: "trash")
                    .font(Theme.meta)
                    .foregroundColor(Theme.danger)
            }
            .buttonStyle(.plain)
            .disabled(cache.cachedKeys.isEmpty)

            Text("只删本地音频文件；要只删某一本书的缓存，去那本书的章节列表里点「删除本书缓存」。")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .fill(Theme.surface)
    }
}
