import SwiftUI

// MARK: - 播放页（设计 §6.5，截图 04）
//
// 集名居中 → 大封面（215pt / 圆角 16）→ 4 格工具行 → 细进度条 + 白点 → 5 键主控
// 与唔语的两处不同（设计 §12 偏差 4 / 6）：
//   1. 删掉它工具行第一格的「每日抽奖」，以及集名下面两行金色推广文案 —— 我们没有这些模块
//   2. 倍速不放内联滑条（原实现是内联），改成半屏弹层，与唔语一致
//
// 复用既有弹层：EpisodeListSheet / RateSheet / SleepSheet / SkipSettingsSheet / BookInfoSheet（逻辑不改，只换壳）

struct PlayerScreen: View {
    @ObservedObject private var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showEpisodes = false
    @State private var showSkip = false
    @State private var showRate = false
    @State private var showSleep = false
    @State private var showInfo = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                titleBlock

                // 音频地址解析中要**看得见**：以前这一步卡住时界面毫无反应，
                // 表现为"点进去没有声音"（真机反馈过 22听书）
                if player.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.8).tint(Theme.accent)
                        Text("正在准备音频…")
                            .font(Theme.metaSmall)
                            .foregroundColor(Theme.text2)
                    }
                }

                if let error = player.errorText {
                    Text(error)
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.danger)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                }

                CoverImage(
                    url: player.book?.cover ?? "",
                    side: 215,
                    radius: Theme.Radius.coverHero
                )

                Spacer(minLength: 0)

                toolRow
                progressBlock
                controlRow
            }
            .padding(.horizontal, Theme.Space.page)
            .padding(.bottom, 14)
            .background(Theme.bg)
            .toolbar(.visible, for: .navigationBar)
            .navigationTitle(player.book?.title ?? "正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .tint(Theme.text1)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("详情") { showInfo = true }
                        .font(Theme.metaSmall)
                        .tint(Theme.accent)
                }
            }
            .sheet(isPresented: $showEpisodes) {
                // 选集
                EpisodeListSheet()
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showRate) {
                // 倍速：改成半屏弹层（原来是在播放页里内联一条滑条）
                RateSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showSleep) {
                SleepSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showSkip) {
                SkipSettingsSheet()
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showInfo) {
                BookInfoSheet()
                    .presentationDetents([.medium, .large])
            }
        }
    }

    // MARK: 集名

    private var titleBlock: some View {
        Text(player.currentEpisode?.title ?? "未在播放")
            .font(Theme.listTitle)
            .foregroundColor(Theme.text1)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.top, 8)
    }

    // MARK: 工具行（4 格；唔语是 5 格，第一格「每日抽奖」已删）

    private var toolRow: some View {
        HStack(spacing: 0) {
            Menu {
                Button("不打开定时") { player.setSleep(minutes: nil) }
                Button("15 分钟") { player.setSleep(minutes: 15) }
                Button("30 分钟") { player.setSleep(minutes: 30) }
                Button("60 分钟") { player.setSleep(minutes: 60) }
                if player.stopAfterEpisode {
                    Button("取消「听完本集停止」") { player.stopAfterEpisode = false }
                } else {
                    Button("听完本集停止") { player.stopAfterEpisode = true }
                }
                Button("自定义…") { showSleep = true }
            } label: {
                toolLabel("timer", sleepTitle)
            }

            Button { showEpisodes = true } label: { toolLabel("list.bullet", "列表") }
            Button { showRate = true } label: { toolLabel("speedometer", rateLabel(player.rate)) }
            Button { showSkip = true } label: { toolLabel("arrow.right.to.line", "片头片尾") }
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.text1)
    }

    private func toolLabel(_ icon: String, _ title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22))
            Text(title)
                .font(Theme.caption)
        }
        .frame(maxWidth: .infinity)
    }

    private var sleepTitle: String {
        guard let deadline = player.sleepDeadline else { return "定时" }
        return "\(max(0, Int(deadline.timeIntervalSinceNow / 60)))分"
    }

    // MARK: 进度

    private var progressBlock: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { min(player.position, max(player.duration, 1)) },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 1)
            )
            .tint(Theme.text1)

            HStack {
                Text(timeText(player.position))
                    .font(Theme.time)
                    .foregroundColor(Theme.text1)
                    .monospacedDigit()
                Spacer()
                Text(timeText(player.duration))
                    .font(Theme.time)
                    .foregroundColor(Theme.text1)
                    .monospacedDigit()
            }
        }
    }

    private func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "00:00" }
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: 主控（中间是白色**实心**圆 + 黑三角；系统那个带圆圈线的播放符号是线框圆，不能用）

    private var controlRow: some View {
        HStack(spacing: 26) {
            Button { player.skip(-15) } label: {
                Image(systemName: "gobackward.15").font(.system(size: 25))
            }

            Button { player.previous() } label: {
                Image(systemName: "backward.end.fill").font(.system(size: 26))
            }

            Button { player.toggle() } label: {
                ZStack {
                    Circle()
                        .fill(Theme.text1)
                        .frame(width: 72, height: 72)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(Theme.dialogText)
                }
            }

            Button { player.next() } label: {
                Image(systemName: "forward.end.fill").font(.system(size: 26))
            }

            Button { player.skip(15) } label: {
                Image(systemName: "goforward.15").font(.system(size: 25))
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(Theme.text1)
        .padding(.bottom, 6)
    }
}
