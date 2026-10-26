import Foundation
import Combine

/// 菜单 / 快捷键 → 视图的一次性指令中转。
///
/// 为什么需要它：Scene 级 `.commands` 够不到 `MainSplitView` 的 `@State`
/// （比如「新建 SSH 会话」的 sheet 是否展开）。这和 `TerminalFocus`、
/// `TerminalQuoteStore` 是同一类问题——**菜单在视图树之外**，
/// 单例 + `@Published` 仍然是最短路径（环境值跨不过 Scene 边界）。
///
/// 为什么用自增计数而不是 Bool：同一指令连按两次不该被合并成一次。
/// 视图侧用 `onChange` 消费计数，消费完**不需要复位**——复位反而会丢掉
/// 「连点两下」里的第二下。
@MainActor
final class AppCommandCenter: ObservableObject {
    static let shared = AppCommandCenter()
    private init() {}

    /// ⇧⌘N：请求打开「新建 SSH 会话」表单。
    @Published private(set) var newSSHSessionRequests = 0

    func requestNewSSHSession() {
        newSSHSessionRequests += 1
    }
}
