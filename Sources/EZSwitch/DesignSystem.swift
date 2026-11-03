import SwiftUI
import AppKit

// MARK: - 设计令牌

/// 全应用共享的语义色、间距与圆角。
///
/// 所有颜色都是动态色：固定色用 `adaptiveColor` 成对声明浅/深值，页面画布直接取
/// AppKit 的 `controlBackgroundColor`；同一份声明在 Aqua 与 Dark Aqua 下解析出不同值，
/// 页面不需要自己读取 `colorScheme`。层次只靠三档中性面建立：
/// `canvas`（页面）→ `surface`（卡片）→ `inset`（卡片内嵌块）。
/// 这里不使用渐变、发光或彩色图标基座，品牌蓝只用于主操作、选中态和主指标。
enum AppDesign {
    // MARK: 语义色

    /// 品牌强调：克制的中性蓝，只用于主操作、选中态与主指标数值。
    static let brand: Color = adaptiveColor(light: 0x2F6BE0, dark: 0x6F9DF0)
    /// 页面画布：系统原生的内容底色（`controlBackgroundColor`）。浅色下与白色标题栏同色、
    /// 连续过渡，深色下随 Aqua 自动变暗；卡片改由 0.5pt `cardBorder` 淡描边与极轻投影立起。
    static let canvas: Color = Color(nsColor: .controlBackgroundColor)
    /// 卡片表面：浅色为纯白，与画布同色，靠 0.5pt 淡描边与轻投影区分；深色比画布亮一档。
    static let surface: Color = adaptiveColor(light: 0xFFFFFF, dark: 0x262629)
    /// 内嵌块：指标块、代码块、地址胶囊等卡片内部的次级表面。
    static let inset: Color = adaptiveColor(light: 0xF5F5F7, dark: 0x1F1F22)
    /// 悬停底色：表格行、可点击卡片的悬停反馈。
    static let hover: Color = adaptiveColor(light: 0xECECEF, dark: 0x333338)
    /// 分隔描边：输入框、胶囊与图表节点的 1pt 边界。卡片改用更淡的 `cardBorder`。
    static let border: Color = adaptiveColor(light: 0xDCDCE1, dark: 0x3D3D42)
    /// 卡片描边：比 `border` 更淡，配合 0.5pt 描边与极轻投影，避免边框压过卡片内容。
    static let cardBorder: Color = adaptiveColor(light: 0xE8E8EC, dark: 0x38383D)
    static let success: Color = adaptiveColor(light: 0x1C8B54, dark: 0x4DBE7D)
    static let warning: Color = adaptiveColor(light: 0xB26B00, dark: 0xE0A84E)
    static let danger: Color = adaptiveColor(light: 0xC43C33, dark: 0xF0736A)
    /// 图表输入序列色。
    static let chartInput: Color = adaptiveColor(light: 0x3F79DD, dark: 0x7BA3EE)
    /// 图表输出序列色。
    static let chartOutput: Color = adaptiveColor(light: 0x2C9A80, dark: 0x4CBFA2)

    /// 间距：页面外边距 / 卡片内边距 / 区块间距。
    enum Space {
        static let page: CGFloat = 24
        static let card: CGFloat = 16
        static let section: CGFloat = 16
    }

    /// 圆角：卡片 / 内嵌块 / 表格行。
    enum Radius {
        static let card: CGFloat = 16
        static let inset: CGFloat = 10
        static let row: CGFloat = 6
    }
}

/// 0xRRGGBB → 随系统外观解析的 sRGB 动态色。
private func adaptiveColor(light: UInt32, dark: UInt32) -> Color {
    let resolved = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(srgbRGB: isDark ? dark : light)
    }
    return Color(nsColor: resolved)
}

private extension NSColor {
    convenience init(srgbRGB rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                  green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - 统一卡片表面

/// 唯一的卡片生产实现。`cardSurface` 与 `ezsCardSurface` 都只是这个 modifier 的薄封装，
/// 避免两套表面各自维护半径、描边和阴影。
///
/// - `clipsContent`：只有需要把内容（例如原生表格的四角）裁进圆角的卡片才打开。
///   原生 `NSTableView` 放在裁剪容器里会失去部分绘制余量，所以默认关闭。
/// - `trailingInset`：给投影留出水平余量，保持既有页面宽度不回跳。
///
/// 外圈固定 0.5pt `cardBorder` 淡描边与 0.03 黑阴影，让卡片边界存在但不抢内容。
struct CardSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = AppDesign.Radius.card
    var padding: CGFloat = 0
    var clipsContent = false
    var trailingInset: CGFloat = 0

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .padding(padding)
            .modifier(CardSurfaceClip(shape: shape, enabled: clipsContent))
            .background {
                shape
                    .fill(AppDesign.surface)
                    .shadow(color: Color.black.opacity(0.03), radius: 3, y: 1)
            }
            .overlay(shape.strokeBorder(AppDesign.cardBorder, lineWidth: 0.5))
            .padding(.trailing, trailingInset)
    }
}

/// 仅在需要时裁剪内容；用一层小 modifier 避免 `AnyView`。
private struct CardSurfaceClip: ViewModifier {
    let shape: RoundedRectangle
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(shape)
        } else {
            content
        }
    }
}

// MARK: - 页面级组件

/// 紧凑页面标题：标题 + 一句说明。需要主操作时由页面自己用 `HStack` 包住，
/// 这里不预留 actions 参数，避免每个页面都把按钮塞进标题组件。
struct AppPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.title2.weight(.semibold))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 数量胶囊：列表标题旁的轻量计数，不抢标题和主操作的注意力。
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(AppDesign.inset, in: Capsule())
            .overlay(Capsule().strokeBorder(AppDesign.border, lineWidth: 1))
            .accessibilityLabel("\(count) 项")
    }
}

/// 页面级空 / 加载 / 错误状态：统一的符号基座、字型与留白。
/// 这里不接收操作按钮，需要就地操作的页面可以自己追加，或在列表内使用 `EmptyState`。
struct AppPageState: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .background(
                    AppDesign.inset,
                    in: RoundedRectangle(cornerRadius: AppDesign.Radius.inset, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppDesign.Radius.inset, style: .continuous)
                        .strokeBorder(AppDesign.border, lineWidth: 1)
                )
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .accessibilityElement(children: .combine)
    }
}
