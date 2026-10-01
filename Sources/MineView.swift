import SwiftUI

// MARK: - 「我的」页（设计 §3：三页签里的第三项）
//
// 版式参考截图 06 的**结构**：顶部一行（标题 + 右侧「设置」）→ 统计卡 → 卡片菜单。
// 唔语这里的「抽奖 / 畅听 / 小红花 / 超级用户」是它的商业模块，**不复刻**（设计 §12 偏差 4）；
// 我们换成三条本地真数据：收藏 / 播放记录 / 已缓存。
//
// 切片一边界：菜单里的三个旧页面（播放记录 / 设置 / 诊断）**保留原视觉**，只保证入口可用；
// 它们的界面重做留切片二。

struct MineView: View {
    @ObservedObject private var library = LibraryStore.shared
    @ObservedObject private var cache = CacheManager.shared

    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var showCache = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topBar
                    statsCard
                    menuCard
                }
                .padding(.horizontal, Theme.Space.page)
                .padding(.top, 12)
                .padding(.bottom, 28)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showHistory) { HistoryView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
            .sheet(isPresented: $showCache) { CacheView() }
        }
    }

    // MARK: 顶部

    private var topBar: some View {
        HStack {
            Text("我的")
                .font(Theme.pageTitle)
                .foregroundColor(Theme.text1)

            Spacer(minLength: 8)

            Button { showSettings = true } label: {
                Label("设置", systemImage: "gearshape")
                    .font(Theme.meta)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.text1)
        }
    }

    // MARK: 统计卡（唔语那张四列卡的版式，内容换成本地真数据）

    private var statsCard: some View {
        HStack(spacing: 0) {
            stat(value: "\(library.favorites.count)", label: "收藏")
            verticalSeparator
            stat(value: "\(library.history.count)", label: "播放记录")
            verticalSeparator
            stat(value: cache.sizeText(), label: "已缓存")
        }
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(Theme.statNumber)
                .foregroundColor(Theme.text1)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text2)
        }
        .frame(maxWidth: .infinity)
    }

    private var verticalSeparator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(width: 1, height: 30)
    }

    // MARK: 菜单卡

    private var menuCard: some View {
        VStack(spacing: 0) {
            menuRow(icon: "clock.arrow.circlepath", title: "播放记录") { showHistory = true }
            rowSeparator
            // 缓存管理的**唯一入口**（设置页里那一段已删除，不再有第二个地方能改同一件事）
            menuRow(icon: "arrow.down.circle", title: "缓存管理", trailing: cache.sizeText()) { showCache = true }
            rowSeparator
            menuRow(icon: "square.grid.2x2", title: "源管理与设置") { showSettings = true }
            rowSeparator
            menuRow(icon: "stethoscope", title: "诊断 / 源测试") { showDiagnostics = true }
            rowSeparator
            menuRow(icon: "info.circle", title: "关于", trailing: Bundle.main.appVersionText, action: nil)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
    }

    private var rowSeparator: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: 0.5)
            .padding(.leading, 48)
    }

    private func menuRow(
        icon: String,
        title: String,
        trailing: String? = nil,
        action: (() -> Void)?
    ) -> some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundColor(Theme.accent)
                    .frame(width: 22)

                Text(title)
                    .font(Theme.meta)
                    .foregroundColor(action == nil ? Theme.text2 : Theme.text1)

                Spacer(minLength: 8)

                if let trailing {
                    Text(trailing)
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text2)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.text2)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}
