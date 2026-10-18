import SwiftUI
import SwiftData
import Persistence

@main
struct CogniTermApp: App {
    let container: ModelContainer

    init() {
        // 生产库不可用时退化为内存库，保证 UI 仍可启动（并在诊断中体现）。
        if let production = try? PersistenceStack.defaultContainer() {
            container = production
        } else {
            // swiftlint:disable:next force_try
            container = try! PersistenceStack.inMemoryContainer()
        }
    }

    var body: some Scene {
        WindowGroup("CogniTerm") {
            MainSplitView()
                .modelContainer(container)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
        // 快捷键走 `.commands` 修饰器（SDK 里没有可构造的顶层 `Commands` 值，
        // 只有 `func commands(@ContentBuilder)` 这个 Scene 修饰器）。
        .commands {
            TerminalCommands()
        }

        Settings {
            SettingsView(sidecar: SidecarService.shared)
                .modelContainer(container)
                .frame(width: 480, height: 460)
        }
    }
}

/// 「终端」菜单：把 iTerm2 / Terminal.app 的事实标准键位补上。
///
/// 快捷键走**宿主菜单**而不是覆盖 `performKeyEquivalent`：后者在 SwiftTerm 里是
/// `public override`（非 open），模块外禁覆盖；而且上游在 `keyDown` 里明写
/// "The host menu owns its shortcuts" —— 带 Command 的键它会先问一次
/// `NSApp.mainMenu`，菜单接了就不再发给 shell。所以正确做法就是装菜单项，
/// 让 AppKit 的既有机制干活。
///
/// ⌘C / ⌘V / ⌘A **不在这里接管**：SwiftTerm 自己实现了 `copy(_:)` / `paste(_:)` /
/// `selectAll(_:)` responder 动作（`MacTerminalView.swift:3415/3434/3446`），走
/// `keyDown → interpretKeyEvents → doCommand` 路径，和系统 Edit 菜单天然配合。
/// 再包一层只会把标准行为复制一遍。
///
/// 焦点守卫：菜单项在 App 里到处都按得到。不判焦点就会在聊天输入框里按 ⌘K
/// 把终端清屏、按 ⌘R 把 shell 重启 —— 而用户根本没在看终端。
@MainActor
struct TerminalCommands: Commands {
    @ObservedObject private var focus = TerminalFocus.shared
    /// 动作作用于**活跃会话**（本地或 SSH）——菜单在 App 级，够不到窗口状态，
    /// 账户由 SessionManager 这个进程级注册表持有。
    @ObservedObject private var sessions = SessionManager.shared
    /// 面板折叠态（与 MainSplitView 共享同一个 UserDefaults 键）。
    /// 走 @AppStorage 而不是 @State：菜单是 Scene 级，够不到 MainSplitView 的
    /// @StateObject；两处状态不一致时菜单折叠了界面不折叠。
    @AppStorage("terminalPanelCollapsed") private var terminalPanelCollapsed = false

    var body: some Commands {
        CommandMenu("终端") {
            Button("清屏") { sessions.activeSession.handleShortcut(.clear) }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!enabled)
            Button("查找…") { sessions.activeSession.handleShortcut(.find) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!enabled)

            // 选区 → agent 上下文（VS Code「Add to Chat」同款）。
            // ⌘I 而不是 ⌘↵：⌘↵ 在 ComposerView 是发送键，不能抢。
            Button("询问 Agent…") { sessions.activeSession.askAgentWithSelection() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!focus.isTerminalFocused)

            // 当前屏幕 → agent：懒得拖选时发「眼睛正看着的这一屏」。
            // 不判焦点：读的是缓冲区内容，终端没聚焦也照常可发。
            Button("发送当前屏幕给 Agent…") { sessions.activeSession.sendScreenToAgent() }
                .keyboardShortcut("i", modifiers: [.command, .shift])

            Divider()

            Button("重启 Shell") { sessions.activeSession.handleShortcut(.restart) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!focus.isTerminalFocused)
            Button("中断") { sessions.activeSession.handleShortcut(.interrupt) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!enabled)

            // 面板折叠：只想专心聊天时把终端面板（默认 220pt）整个让给对话区。
            // 窗口级动作，不判终端焦点——用户没聚焦终端也可能想收起它。
            // 高度记忆在 terminalPanelHeight 里，展开即恢复，不是删除。
            Button(terminalPanelCollapsed ? "展开终端" : "折叠终端") {
                terminalPanelCollapsed.toggle()
            }
            .keyboardShortcut("j", modifiers: .command)

            Divider()

            Button("放大字号") { sessions.activeSession.handleShortcut(.zoomIn) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!focus.isTerminalFocused)
            Button("缩小字号") { sessions.activeSession.handleShortcut(.zoomOut) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!focus.isTerminalFocused)
            Button("实际字号") { sessions.activeSession.handleShortcut(.zoomReset) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!focus.isTerminalFocused)
        }
    }

    /// 需要 shell 真的在跑的动作。焦点 + 运行态两个条件都满足才启用。
    private var enabled: Bool {
        focus.isTerminalFocused && sessions.activeSession.status.isRunning
    }
}
