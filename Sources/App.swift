import SwiftUI
import UIKit

@main
struct MyTingShuApp: App {
    init() {
        // 后台播放：进入后台也继续出声
        PlayerEngine.shared.prepareForBackgroundAudio()
        Self.configureChrome()
    }

    /// 纯黑底（设计 §4.1）：系统 TabView / 导航栏默认带半透明材质，
    /// 在深色下也不是纯黑，压成不透明黑才和唔语一致。
    private static func configureChrome() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.bg)
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.bg)
        nav.titleTextAttributes = [.foregroundColor: UIColor(Theme.text1)]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.text1)]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            // 只做深色主题（唔语本身就只有一个纯黑深色外观）
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    var body: some View {
        // 三页签对齐唔语：书架 / 发现 / 我的（原「搜索 / 书源 / 历史 / 设置」不再占页签，
        // 搜索降为书架页顶部胶囊入口，历史与设置在「我的」里）
        // 迷你播放条挂在每个页签内容的底部（而不是挂在 TabView 上），这样它不会盖住底部 dock 栏。
        TabView {
            ShelfView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
            DiscoverView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("发现", systemImage: "flame.fill") }
            MineView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("我的", systemImage: "person.fill") }
        }
        .tint(Theme.accent)
        .background(Theme.bg)
    }
}
