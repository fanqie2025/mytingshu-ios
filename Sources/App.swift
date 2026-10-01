import SwiftUI

@main
struct MyTingShuApp: App {
    init() {
        // 后台播放：进入后台也继续出声
        PlayerEngine.shared.prepareForBackgroundAudio()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        // 迷你播放条挂在每个页签内容的底部（而不是挂在 TabView 上），
        // 这样它不会盖住底部 dock 栏。
        TabView {
            BookshelfView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("书架", systemImage: "books.vertical.fill") }
            SearchView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            HomeView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("书源", systemImage: "square.grid.2x2") }
            HistoryView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            SettingsView()
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
    }
}
