import SwiftUI

// MARK: - 章节抽屉（设计 §6.4 的下半部分，截图 03）
//
// 这里是**内容**：当前集一行 + 编号章节列表。抽屉的高度与拖拽由 `DetailView` 负责，
// 这样本组件只关心"列出章节、点一下播、下载一集"三件事。

/// 抽屉顶部那一行：当前集 chip（唔语是「一人得道」那个深色胶囊）+ 「选集」
struct EpisodeDrawerHeader: View {
    let episodes: [Episode]
    let currentIndex: Int?

    var body: some View {
        HStack(spacing: 10) {
            if let currentIndex, episodes.indices.contains(currentIndex) {
                let episode = episodes[currentIndex]
                Text("第 \(currentIndex + 1) 集 · \(episode.title.isEmpty ? "未命名" : episode.title)")
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.text1)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.bg))
            } else {
                Text("共 \(episodes.count) 集")
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.text2)
            }

            Spacer(minLength: 8)

            Text("选集")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.accent)
        }
        .padding(.horizontal, Theme.Space.page)
    }
}

struct EpisodeDrawer: View {
    let episodes: [Episode]
    let currentIndex: Int?
    let onSelect: (Int) -> Void
    /// 目录还有下一页（懒加载）
    let hasMore: Bool
    /// 正在拉下一页
    let loadingMore: Bool
    /// 上一次拉取失败（显示成可点的重试，避免自动重试打转）
    let loadMoreFailed: Bool
    /// 拉下一页：列表滑到底时自动触发（=「不滑动不加载」）
    let onLoadMore: () -> Void

    var body: some View {
        // 注：这里曾有「缓存接下来 10 集」批量下载按钮，已按用户要求移除 ——
        // 连续拉多个音频最容易招源站风控。单集下载（每行那个 ↓）保留：
        // 它和"点开这一集播放"是同一个请求量级，不额外增加风险。
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.offset) { index, episode in
                            row(index: index, episode: episode)
                                .id(index)
                        }
                        loadMoreRow
                    }
                }
                .onAppear {
                    if let currentIndex, episodes.indices.contains(currentIndex) {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: 懒加载：滑到底才拉下一页（大长篇的目录页数很多，一次拉完会等几十秒还会被 429）

    @ViewBuilder private var loadMoreRow: some View {
        if hasMore || loadMoreFailed {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if loadingMore {
                    ProgressView().scaleEffect(0.7)
                    Text("加载更多…")
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text2)
                } else {
                    Button(loadMoreFailed ? "加载失败，点这里重试" : "加载更多（已 \(episodes.count) 集）") {
                        onLoadMore()
                    }
                    .font(Theme.metaSmall)
                    .foregroundColor(loadMoreFailed ? Theme.danger : Theme.accent)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .onAppear {
                // 滑到这里才自动加载；失败过后不自动重试（会打转），改为点按钮
                if hasMore, !loadingMore, !loadMoreFailed { onLoadMore() }
            }
        } else if !episodes.isEmpty {
            Text("已全部加载（\(episodes.count) 集）")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }

    // MARK: 单集行（只有编号 + 标题，点一下播放）
    // 单集 ↓ 缓存按钮已按用户要求移除（连同批量缓存、自动缓存）——
    // App 现在**不产生任何下载**，只保留"能播之前缓存过的旧文件 + 能清空"。

    private func row(index: Int, episode: Episode) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
                .frame(width: 34, alignment: .trailing)

            Text(episode.title.isEmpty ? "第 \(index + 1) 集" : episode.title)
                .font(Theme.meta)
                .foregroundColor(index == currentIndex ? Theme.accent : Theme.text1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }
}
