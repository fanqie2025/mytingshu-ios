import SwiftUI

// MARK: - 书架页（设计 §6.1，截图 01 / 07 / 08）
//
// 结构：搜索胶囊 → 标题行（我的书架 + 编辑/提示/清空书架）→ 4 列近方形封面网格 → 迷你条
// 编辑态：封面右上角红 ✕ 移除；本轮**不做长按拖拽排序**（设计 §8.1 边界决策）
// 这页没有系统导航栏，大标题写在内容里（唔语就是这样）

struct ShelfView: View {
    @ObservedObject private var library = LibraryStore.shared

    @State private var editing = false
    @State private var showClearConfirm = false
    @State private var showTips = false
    @State private var showSearch = false

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.Space.gridGap),
        count: 4
    )

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SearchPillButton(placeholder: "点击搜索，支持搜书、分类、演播者等") {
                        showSearch = true
                    }
                    .padding(.top, 8)

                    header

                    if library.favorites.isEmpty {
                        StateView(
                            kind: .empty,
                            title: "无收藏，请通过搜索添加喜爱的书",
                            message: nil,
                            actionTitle: nil,
                            action: nil
                        )
                        .padding(.top, 60)
                    } else {
                        grid
                    }
                }
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Book.self) { book in
                // T9: 接 DetailView(book: book)
                Text("详情页待接：\(book.title)")
                    .font(Theme.meta)
                    .foregroundColor(Theme.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg)
            }
            .sheet(isPresented: $showSearch) {
                // T9: 接 SearchScreen()
                Text("搜索页待接")
                    .font(Theme.meta)
                    .foregroundColor(Theme.text2)
            }
            .overlay {
                if showTips {
                    ConfirmDialog(
                        isPresented: $showTips,
                        title: "功能提示",
                        // 唔语原文第一条是「长按书籍封面,可拖动调整书籍位置」——本轮不做拖拽排序，
                        // 照抄就是骗自己，故改写为实际行为（见设计 §12 偏差 7 / 台账裁定）
                        items: [
                            "点封面右上角 ✕ 可从书架移除",
                            "在搜索页面长按列表, 可添加书籍至书架"
                        ],
                        confirmTitle: "确认",
                        onConfirm: {}
                    )
                }
                if showClearConfirm {
                    ConfirmDialog(
                        isPresented: $showClearConfirm,
                        title: "清空书架",
                        items: ["点击确认会删除当前书架中的所有书籍"],
                        confirmTitle: "确认",
                        onConfirm: { library.clearFavorites() }
                    )
                }
            }
        }
    }

    /// 标题行：大标题 + 三个蓝色文字动作（截图 01 / 07）
    private var header: some View {
        HStack(spacing: 14) {
            Text("我的书架")
                .font(Theme.pageTitle)
                .foregroundColor(Theme.text1)

            Spacer(minLength: 8)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) { editing.toggle() }
            } label: {
                Label(editing ? "完成" : "编辑", systemImage: editing ? "checkmark.circle" : "pencil.circle")
                    .font(Theme.meta)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.accent)

            Button {
                showTips = true
            } label: {
                Label("提示", systemImage: "info.circle")
                    .font(Theme.meta)
            }
            .buttonStyle(.plain)
            .foregroundColor(Theme.accent)

            Button("清空书架") { showClearConfirm = true }
                .buttonStyle(.plain)
                .font(Theme.meta)
                .foregroundColor(Theme.accent)
                .disabled(library.favorites.isEmpty)
        }
        .padding(.horizontal, Theme.Space.page)
    }

    /// 4 列网格；非编辑态每格是进详情的 NavigationLink（value-based，见 Components.swift 顶部说明）
    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.sectionGap) {
            ForEach(library.favorites) { book in
                if editing {
                    CoverGridCell(book: book, editing: true) {
                        library.toggleFavorite(book)
                    }
                } else {
                    NavigationLink(value: book) {
                        CoverGridCell(book: book, editing: false) {}
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, Theme.Space.page)
    }
}
