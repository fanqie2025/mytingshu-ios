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
        TabView {
            HomeView().tabItem { Label("书源", systemImage: "books.vertical") }
            SearchView().tabItem { Label("搜索", systemImage: "magnifyingglass") }
            FavoritesView().tabItem { Label("收藏", systemImage: "heart") }
            HistoryView().tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
    }
}
