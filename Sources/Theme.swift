import SwiftUI

/// 设计 token —— 全部界面取值集中在这里
///
/// 依据：`wodetingshu/ios/docs/specs/2026-10-02-ui-redesign-design.md` §4
/// 纪律：**页面代码禁止出现颜色 / 圆角 / 间距字面量**，一律引用 `Theme.*`
/// 主题：只做深色（唔语本身就是纯黑深色 App），根视图用 `.preferredColorScheme(.dark)`
enum Theme {

    // MARK: - 颜色（设计 §4.1）

    /// 全局背景。唔语是**纯黑**，不是 `systemBackground` 的深灰
    static let bg = Color(hex: 0x000000)
    /// 卡片 / 迷你条 / 我的页菜单卡 / 章节抽屉
    static let surface = Color(hex: 0x1C1C1E)
    /// 分隔线、搜索胶囊描边
    static let separator = Color(hex: 0x2C2C2E)
    /// 交互色 = **iOS 系统蓝**。唔语的选中页签、按钮文字、迷你条播放三角都是系统蓝，
    /// 不是它的品牌红 —— 照抄这一点才像
    static let accent = Color.blue
    /// 品牌红：只用于 Logo / 品牌图标（唔语的 `flower.png` 花瓣）
    static let brand = Color(hex: 0xEA5252)
    /// 唔语的推广金（每日抽奖 / 畅听提示）。我们删掉了全部推广模块，此 token 备用
    static let gold = Color(hex: 0xFABB28)
    static let text1 = Color(hex: 0xFFFFFF)
    static let text2 = Color(hex: 0x8E8E93)
    static let danger = Color(hex: 0xFF453A)
    static let success = Color(hex: 0x30D158)

    /// 白色确认弹窗的底色 / 文字色 —— 唔语在纯黑 App 里的唯一浅色例外（截图 08）
    static let dialogBG = Color(hex: 0xFFFFFF)
    static let dialogText = Color(hex: 0x000000)
    /// 弹窗背后的遮罩
    static let scrim = Color(hex: 0x000000)

    // MARK: - 字体（系统字体，不引任何字体文件；设计 §4.3）

    /// 页面大标题：「我的书架」28–30 bold
    static let pageTitle = Font.system(size: 29, weight: .bold)
    /// 区段标题：「热榜」「最近更新」20–22 bold
    static let sectionTitle = Font.system(size: 21, weight: .bold)
    /// 导航栏标题：「详情」17 semibold
    static let navTitle = Font.system(size: 17, weight: .semibold)
    /// 列表主标题：搜索结果、章节名、播放页集名（同为 16–17 semibold）
    static let listTitle = Font.system(size: 17, weight: .semibold)
    /// 详情页简介正文：17–19 regular，行距约 1.5（唔语这页字明显大而疏松）
    static let body = Font.system(size: 18, weight: .regular)
    /// 次要文字：摘要、演播 / 作者 13–14
    static let meta = Font.system(size: 14, weight: .regular)
    static let metaSmall = Font.system(size: 13, weight: .regular)
    /// 页签标签、播放页工具行标签 10–11
    static let caption = Font.system(size: 10.5, weight: .regular)
    /// 白色确认弹窗的标题 24 bold
    static let dialogTitle = Font.system(size: 24, weight: .bold)

    // MARK: - 字体（增补，设计 §4.3 要求但计划签名未列出；见台账 裁定 1）

    /// 详情页三列统计数字 26–28 bold
    static let statNumber = Font.system(size: 27, weight: .bold)
    /// 播放页进度两端时间 14–15
    static let time = Font.system(size: 15, weight: .regular)

    // MARK: - 圆角（设计 §4.4）

    enum Radius {
        /// 书架 / 分类网格封面
        static let coverGrid: CGFloat = 6
        /// 搜索结果行封面
        static let coverList: CGFloat = 8
        /// 卡片、详情页头部封面
        static let card: CGFloat = 12
        /// 播放页大封面
        static let coverHero: CGFloat = 16
        /// 迷你条上的圆形封面（= 直径 ÷ 2）
        static let coverMini: CGFloat = 20
        /// 小胶囊 / 小按钮：分类 chip、弹窗确认按钮
        static let chip: CGFloat = 8
    }

    // MARK: - 间距（设计 §4.4）

    enum Space {
        /// 页面左右边距
        static let page: CGFloat = 16
        /// 列表行内 / 网格列间距
        static let row: CGFloat = 8
        /// 网格列间距
        static let gridGap: CGFloat = 8
        /// 区块之间（网格行距含 1 行标题 = 24）
        static let sectionGap: CGFloat = 24
    }
}

// MARK: - App 元信息

extension Bundle {
    /// `0.2.0 (2)` —— 一律从 Info.plist 读，禁止在界面里硬编码版本号
    var appVersionText: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

// MARK: - 十六进制颜色（只允许在 Theme.swift 内使用）

extension Color {
    /// `Color(hex: 0x1C1C1E)` —— 本文件之外不要再出现色值字面量
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
