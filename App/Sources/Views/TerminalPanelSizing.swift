import Foundation
import AppKit

/// 终端面板该多高。
///
/// ## 为什么不再用一个写死的默认值
///
/// 旧实现固定 220pt。这 220pt 里有 56pt 是别人的地盘——标签栏 26 + 两条分隔线 2 +
/// 工具条 28（图标 18 + 上下各 5 内边距），留给终端本身只有 164pt。
/// 而 SwiftTerm 的单元格高度是 `ceil(ascent + descent + leading)`（见
/// `AppleTerminalView.computeFontDimensions`，`_lineSpacing` 默认 1.0），
/// 默认字号 12pt 的 SF Mono 实测 **15pt** 一格。于是 164/15 ≈ **10.9 行** ——
/// 一条 `git status` 就得开滚，`ls -la` 更是看不到一半。
///
/// 关键在于：**终端的有用程度是按「行」算的，不是按 pt 算的**。
/// 同一个 220pt，字号调到 20pt 就只剩 6 行多；反过来放大字号本该看得更清，
/// 实际却看得更少。所以这里的基准单位是「行」，pt 只是换算结果。
///
/// ## 三个约束，取舍写在 `idealHeight` 里
///
/// 1. 至少看得见多少行（`minimumRows`）—— 撑开的下限；
/// 2. 窗口越高越该多给（`comfortableRatio`）—— 但比例单独用不够，
///    在 600pt 高的窗口上 0.42 只有 240pt，比行数下限还矮；
/// 3. 对话区不能低于 `conversationFloor` —— 封顶。这条和
///    `MainSplitView` 里对话区那块 `.frame(minHeight:)` 是**同一个数**，
///    改一个必须改另一个，所以从常量取，别写字面量。
///
/// 三条一起用时冲突难免（窗口矮的时候行数下限会被封顶顶掉），
/// 优先级是 **对话区下限 > 行数下限 > 比例**：宁可终端矮，不能把对话区挤没。
enum TerminalPanelSizing {

    // MARK: - 面板里不属于终端的那部分

    /// `TerminalTabBar` 固定 `.frame(height: 26)`。
    static let tabBarHeight: CGFloat = 26
    /// 工具条：图标 `.frame(width: 20, height: 18)` + `.padding(.vertical, 5)`。
    static let toolbarHeight: CGFloat = 28
    /// 标签栏下一条、工具条下一条。
    static let dividerHeight: CGFloat = 2
    /// 全部非终端像素。改了上面三个必须跟着改——否则「几行」的换算是假的。
    static var chromeHeight: CGFloat { tabBarHeight + toolbarHeight + dividerHeight }

    // MARK: - 三个约束

    /// 下限行数。
    ///
    /// 8 行是「看得见提示符 + 一条短命令的输出」的底线，18 行能装下一份
    /// `git status --short` 或半个 `ls -la`。经典 VT100 是 80×24，
    /// 24 行当然更好，但那要求 416pt 面板——1280×652 这种窗口里
    /// 对话区会只剩 200pt，得不偿失。所以取 18，靠比例在更大的窗口上继续涨。
    static let minimumRows: Double = 18

    /// 窗口够高时按这个比例分。0.42 → 900pt 高约 22 行，1400pt 高约 32 行。
    static let comfortableRatio: Double = 0.42

    /// 对话区的身高下限。**必须与 `MainSplitView` 里对话区的
    /// `.frame(minHeight:)` 一致**。
    static let conversationFloor: CGFloat = 280

    /// 拖拽手柄自身的厚度，算预算时要扣掉。
    static let handleHeight: CGFloat = 4

    /// 拖拽可达的绝对上限（不受窗口影响）。见 `clampedCustomHeight`。
    static let absoluteMax: Double = 1200

    /// 面板矮到这个程度就没意义了（约一行 + chrome），任何钳制都不许低于它。
    static var floorHeight: Double { Double(chromeHeight) + Double(cellHeight(fontSize: 12)) }

    // MARK: - 换算

    /// 一格（一行）的高度。
    ///
    /// 必须和 SwiftTerm 同口径：`ceil((ascent + descent + leading) * lineSpacing)`。
    /// 12pt 的 SF Mono 是 `ceil(11.60 + 2.53) = 15`。差 1pt 看着无所谓，
    /// 但「18 行」在 300pt 上会差出整整一行。
    static func cellHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let raw = font.ascender - font.descender + font.leading
        return max(ceil(raw), 1)
    }

    /// 够 `minimumRows` 行所需的物理高度（含 chrome）。
    static func heightForMinimumRows(fontSize: CGFloat) -> Double {
        Double(chromeHeight) + minimumRows * Double(cellHeight(fontSize: fontSize))
    }

    /// 窗口高度能给终端的上限：再高对话区就破了 `conversationFloor`。
    static func maxBudget(available: CGFloat) -> Double {
        max(Double(available) - Double(conversationFloor) - Double(handleHeight),
            floorHeight)
    }

    /// 自适应高度：比例给量，行数兜底，对话区封顶。
    ///
    /// 用户没手动拖过的时候用它。**它跟着字号走**：放大字号 → 行数下限变高 →
    /// 面板跟着长，不会出现「字越大看得越少」。
    static func idealHeight(available: CGFloat, fontSize: CGFloat) -> Double {
        let byRatio = Double(available) * comfortableRatio
        let byRows = heightForMinimumRows(fontSize: fontSize)
        return displayHeight(desired: max(byRatio, byRows),
                             available: available,
                             fontSize: fontSize)
    }

    /// 把「想要的高度」夹进当前窗口承受得起的区间。
    ///
    /// 下限是行数下限、上限是预算。两者打架时（窗口太矮）以上限为准——
    /// 这条不能反：破了对话区下限，被压缩的就是对话区，而对话区是这个 app 的主体。
    static func displayHeight(desired: Double, available: CGFloat, fontSize: CGFloat) -> Double {
        let floor = heightForMinimumRows(fontSize: fontSize)
        let ceiling = maxBudget(available: available)
        guard ceiling > floor else { return ceiling }
        return min(max(desired, floor), ceiling)
    }

    /// 拖拽时要**存**下来的值。
    ///
    /// 只做宽松钳制，不按当前窗口夹。⛔ 不能存 `displayHeight` 的结果：
    /// 用户把窗口拖小一次，存的值就跟着变小，再把窗口拖大回来也不会恢复——
    /// 「拖小再拖大，终端永久变矮」这种 bug 找起来极费劲。
    static func clampedCustomHeight(_ value: Double) -> Double {
        min(max(value, floorHeight), absoluteMax)
    }

    // MARK: - 可读性

    /// 这个高度在给定字号下能看到多少行（只用于工具提示 / 诊断文案）。
    static func visibleRows(height: Double, fontSize: CGFloat) -> Double {
        max(0, (height - Double(chromeHeight)) / Double(cellHeight(fontSize: fontSize)))
    }
}
