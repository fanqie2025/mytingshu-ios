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
            BookshelfView().tabItem { Label("书架", systemImage: "books.vertical.fill") }
            SearchView().tabItem { Label("搜索", systemImage: "magnifyingglass") }
            HomeView().tabItem { Label("书源", systemImage: "square.grid.2x2") }
            HistoryView().tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }
            SettingsView().tabItem { Label("设置", systemImage: "gearshape") }
        }
        .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
    }
}
