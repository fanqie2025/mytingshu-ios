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
    let onCache: (Int) -> Void
    /// 批量缓存「从这一集开始的 N 集」——组件只出界面，真正调 CacheManager 的是 DetailView
    let onCacheNext: (Int) -> Void
    /// 删除本书已缓存的音频（只删本地，不发请求）
    let onRemoveBookCache: () -> Void

    @ObservedObject private var cache = CacheManager.shared

    var body: some View {
        VStack(spacing: 0) {
            batchRow

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(episodes.enumerated()), id: \.offset) { index, episode in
                            row(index: index, episode: episode)
                                .id(index)
                        }
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

    // MARK: 批量缓存（限量限速，见 CacheManager.batchLimit / batchIntervalSec）

    private var batchRow: some View {
        HStack(spacing: 10) {
            if cache.batching {
                ProgressView().scaleEffect(0.7)
                Text("缓存中 \(cache.batchDone)/\(cache.batchTotal)")
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.text1)
                Spacer(minLength: 8)
                Button("停止") { cache.cancelBatch() }
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.accent)
            } else {
                Button {
                    onCacheNext(currentIndex ?? 0)
                } label: {
                    Label("缓存接下来 \(CacheManager.batchLimit) 集", systemImage: "arrow.down.circle")
                        .font(Theme.metaSmall)
                }
                .buttonStyle(.plain)
                .foregroundColor(Theme.accent)
                .disabled(episodes.isEmpty)

                Spacer(minLength: 8)

                Button("删除本书缓存") { onRemoveBookCache() }
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.text2)
                    .disabled(episodes.isEmpty)
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.bottom, 8)
    }

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

            if cache.isCached(episode.url) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundColor(Theme.success)
            } else if cache.isDownloading(episode.url) {
                ProgressView().scaleEffect(0.7)
            } else {
                Button {
                    onCache(index)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(Theme.text2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(index) }
    }
}
