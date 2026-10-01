import SwiftUI

// MARK: - 共用组件（设计 §5）
//
// 依据：`docs/specs/2026-10-02-ui-redesign-design.md` §5 与 `ref/wuyu/screens/*`
// 纪律：颜色 / 圆角 / 间距 / 字号一律走 `Theme.*`，本文件内不出现色值字面量
// 导航：封面点击用 value-based `NavigationLink(value: book)`，
//       因此**使用本组件的页面必须包在 `NavigationStack` 内并声明
//       `.navigationDestination(for: Book.self) { DetailView(book: $0) }`**

// MARK: 封面

/// 异步封面 + 深灰占位 + 灰色图标 + 圆角。
/// `side == nil` 时撑满父容器、按正方形自适应（4 列网格用，见台账裁定 5）
struct CoverImage: View {
    let url: String
    let side: CGFloat?
    let radius: CGFloat

    init(url: String, side: CGFloat? = nil, radius: CGFloat) {
        self.url = url
        self.side = side
        self.radius = radius
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    private var placeholder: some View {
        ZStack {
            Theme.surface
            Image(systemName: "photo")
                .font(.system(size: (side ?? 80) * 0.22))
                .foregroundColor(Theme.text2)
        }
    }

    @ViewBuilder private var content: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                placeholder
            }
        }
    }

    var body: some View {
        if let side {
            content
                .frame(width: side, height: side)
                .clipShape(shape)
        } else {
            // Color.clear 撑出正方形，再把封面叠上去（网格列宽自适应）
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(content)
                .clipShape(shape)
        }
    }
}

// MARK: 书架网格单元

/// 4 列网格单元：近方形封面 + 1 行标题；编辑态右上角红色 ✕（截图 01 / 07）
struct CoverGridCell: View {
    let book: Book
    let editing: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverImage(url: book.cover, radius: Theme.Radius.coverGrid)
                if editing {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Theme.text1)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.danger))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 7, y: -7)
                }
            }
            Text(book.title)
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text1)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
    }
}

// MARK: 搜索入口胶囊

/// 顶部胶囊搜索入口：放大镜 + 灰色提示语，点一下进搜索页（截图 01）
struct SearchPillButton: View {
    let placeholder: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.accent)
                Text(placeholder)
                    .foregroundColor(Theme.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(Theme.meta)
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(Capsule().fill(Theme.bg))
            .overlay(Capsule().stroke(Theme.accent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Theme.Space.page)
    }
}

// MARK: 搜索结果行

/// 搜索结果行（截图 02）：封面 44 + 标题 2 行 + 摘要 2 行 + 「演播/作者」+ 源名。
/// 源名是**与唔语的有意偏差**（它是单后端所以不标源，我们多源必须能区分）
struct SearchResultRow: View {
    let book: Book
    let sourceName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CoverImage(url: book.cover, side: 44, radius: Theme.Radius.coverList)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(Theme.listTitle)
                    .foregroundColor(Theme.text1)
                    .lineLimit(2)

                if !book.intro.isEmpty {
                    Text(book.intro)
                        .font(Theme.metaSmall)
                        .foregroundColor(Theme.text2)
                        .lineLimit(2)
                }

                HStack(spacing: 10) {
                    if !book.artist.isEmpty { Text("演播：\(book.artist)") }
                    if !book.author.isEmpty { Text("作者：\(book.author)") }
                    Spacer(minLength: 0)
                    Text(sourceName).foregroundColor(Theme.accent)
                }
                .font(Theme.metaSmall)
                .foregroundColor(Theme.text1)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: 横向区段

/// 区段标题 + 「更多」+ 横向封面流（截图 05）。
/// 用在 `NavigationStack` 内：封面是 `NavigationLink(value:)`
struct CarouselSection: View {
    let title: String
    let books: [Book]
    let onMore: (() -> Void)?

    private let coverSide: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.sectionTitle)
                    .foregroundColor(Theme.text1)
                Spacer(minLength: 8)
                if let onMore {
                    Button("更多", action: onMore)
                        .font(Theme.meta)
                        .foregroundColor(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Space.page)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Theme.Space.gridGap) {
                    ForEach(books) { book in
                        NavigationLink(value: book) {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverImage(url: book.cover, side: coverSide, radius: Theme.Radius.coverGrid)
                                Text(book.title)
                                    .font(Theme.metaSmall)
                                    .foregroundColor(Theme.text1)
                                    .lineLimit(1)
                                    .frame(width: coverSide, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Space.page)
            }
        }
    }
}

// MARK: 三态视图

/// 加载 / 空 / 错误三态。
/// 空态插图用 SF Symbol 而非唔语的 `io.png`（见台账裁定 8：不把第三方素材提交进公开仓库）
struct StateView: View {
    enum Kind { case loading, empty, error }

    let kind: Kind
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            switch kind {
            case .loading:
                ProgressView().tint(Theme.accent)
            case .empty:
                Image(systemName: "books.vertical")
                    .font(.system(size: 42))
                    .foregroundColor(Theme.text2)
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 34))
                    .foregroundColor(Theme.gold)
            }

            Text(title)
                .font(Theme.meta)
                .foregroundColor(Theme.text1)
                .multilineTextAlignment(.center)

            if let message, !message.isEmpty {
                Text(message)
                    .font(Theme.metaSmall)
                    .foregroundColor(Theme.text2)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Theme.meta)
                    .foregroundColor(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.Space.page)
        .padding(.vertical, 28)
    }
}

// MARK: 白色确认弹窗

/// 白卡确认弹窗（截图 08）：唔语在深色 App 里唯一的浅色例外。
/// 自带遮罩，用 `.overlay { if show { ConfirmDialog(...) } }` 呈现（见台账裁定 6）
struct ConfirmDialog: View {
    @Binding var isPresented: Bool
    let title: String
    let items: [String]
    let confirmTitle: String
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Theme.scrim.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 18) {
                Text(title)
                    .font(Theme.dialogTitle)
                    .foregroundColor(Theme.dialogText)

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        Text("\(index + 1). \(item)")
                            .font(Theme.body)
                            .foregroundColor(Theme.dialogText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    isPresented = false
                    onConfirm()
                } label: {
                    Text(confirmTitle)
                        .font(Theme.listTitle)
                        .foregroundColor(Theme.text1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                                .fill(Theme.accent)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(22)
            .frame(maxWidth: 300)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Theme.dialogBG)
            )
        }
    }
}
