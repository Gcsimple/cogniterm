import Foundation
import SwiftUI
import Combine
import TerminalCore

/// 终端会话集合：本地 shell + N 个 SSH 远程会话。
///
/// 为什么要有它：`TerminalSession` 原来是进程级单例（一个 PTY 一个终端）。
/// SSH 支持要求同时存在多个会话，而**同一条命令注入到本地还是远程后果完全不同**
/// —— 所以「活跃会话」必须是显式状态，而不是"那个唯一的终端"。
///
/// 职责边界：
/// - 持有 `[TerminalSession]` 与 `activeSessionID`（UI 与菜单都读它）；
/// - 实现 `TerminalCommandExecutor`，把 agent 的 `run_in_terminal` 委托给
///   **当时的活跃会话**（审批卡上会标注目标，见 `commandTargetDescription`）；
/// - 不碰 SwiftData（书签由视图层读写），不碰 MCP（server 只管注册）。
@MainActor
final class SessionManager: ObservableObject {

    static let shared = SessionManager()

    /// 会话列表。本地会话恒在首位且不可关闭。
    @Published private(set) var sessions: [TerminalSession]
    @Published private(set) var activeSessionID: UUID

    /// 活跃会话自身状态变化的转发。Scene 菜单与详情面板观察的是
    /// **SessionManager**，不转发的话活跃会话的 status / title 变了它们不刷新。
    private var activeObservation: AnyCancellable?

    /// 现场恢复只做一次：视图重建时会再次调用，重复恢复会开出一串重复标签。
    private var didRestoreWorkspace = false

    /// 终端现场的落盘位置。**nil = 不落盘**。
    ///
    /// 只有进程级单例（真实 App）才落盘；测试用 `init(local:)` 建实例时不写文件，
    /// 否则跑一次测试就会把用户上次的标签组合覆盖成测试数据。
    private let workspaceFileURL: URL?

    private init() {
        // 本地会话由 TerminalSession.shared 提供（Scene 菜单在列表出现前就引用它）。
        let local = TerminalSession.shared
        sessions = [local]
        activeSessionID = local.id
        workspaceFileURL = TerminalWorkspaceStore.defaultFileURL()
        observeActive()
    }

    /// 测试专用：用独立实例构建，避免污染进程级单例的会话列表。
    ///
    /// - Parameter workspaceFileURL: 传路径才把标签组合落盘（测试用它验恢复逻辑，
    ///   同时不碰真实配置）。默认 nil = 纯内存。
    init(local: TerminalSession, workspaceFileURL: URL? = nil) {
        sessions = [local]
        activeSessionID = local.id
        self.workspaceFileURL = workspaceFileURL
        observeActive()
    }

    private func observeActive() {
        activeObservation = activeSession.objectWillChange.sink { [weak self] _ in
            // 下一拍再发：objectWillChange 先于属性写入。
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    var activeSession: TerminalSession {
        sessions.first { $0.id == activeSessionID } ?? sessions[0]
    }

    var hasActiveRemoteSession: Bool {
        activeSession.kind == .ssh
    }

    // MARK: - 会话操作

    /// 切换活跃会话。焦点交给目标终端——用户点会话名就是为了开始打字。
    func activate(_ id: UUID) {
        guard activeSessionID != id, sessions.contains(where: { $0.id == id }) else { return }
        activeSessionID = id
        observeActive()
        // 视图可能还没 attach（刚建的会话）；下一拍再要焦点，拿不到就算了。
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.activeSession.focusTerminal()
        }
    }

    /// 新建 SSH 会话（同一目标可开多条，各自独立 PTY）。
    ///
    /// - Parameters:
    ///   - target: 已通过语法校验的连接目标。
    ///   - label: 展示名（书签名，或 user@host）。
    ///   - root: 本地 ssh 进程的起始 cwd。用家目录：ssh 不关心 cwd，
    ///     而工作区路径对它毫无意义。
    ///   - remoteDirectory: 远程执行目录（agent 的命令在这里跑）。
    ///     只是**声明**，不会在连接后自动注入 `cd`——连接阶段可能还停在密码
    ///     提示上，那时往 PTY 里打字会把路径当密码交上去。
    @discardableResult
    func openSSHSession(target: SSHTarget,
                        label: String,
                        root: URL,
                        remoteDirectory: String? = nil) -> TerminalSession {
        let session = addSSHSession(target: target, label: label, root: root,
                                    remoteDirectory: remoteDirectory, activate: true)
        persistWorkspace()
        return session
    }

    /// 建一个 SSH 会话但**不一定是用户点的**（恢复现场时不抢焦点）。
    @discardableResult
    private func addSSHSession(target: SSHTarget,
                               label: String,
                               root: URL,
                               remoteDirectory: String? = nil,
                               activate: Bool) -> TerminalSession {
        let session = TerminalSession(kind: .ssh,
                                      label: label,
                                      sshTarget: target,
                                      remoteDirectory: remoteDirectory,
                                      // 只在内存里留一份：密码的来源是 Keychain，
                                      // 用户在表单里勾了「保存密码」才会有值。
                                      password: SSHPasswordStore.password(for: target))
        // 目录改了要重新落盘：终端现场包含它，重启后必须回到同一个位置。
        session.onRemoteDirectoryChanged = { [weak self] in
            self?.persistWorkspace()
        }
        sessions.append(session)
        if activate {
            activeSessionID = session.id
            observeActive()
        }
        session.start(root: root)
        if activate {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                self?.activeSession.focusTerminal()
            }
        }
        return session
    }

    // MARK: - 终端现场（上次的标签组合）

    /// 恢复上次的终端标签。只恢复 SSH —— 本地会话恒在首位且不可关闭。
    ///
    /// 与 `recentSessions` 的分工：那是 **agent 对话**的历史（回去继续聊），
    /// 这是 **终端现场**（上次开着哪些机器）。terminal 产品真正想恢复的是后者。
    ///
    /// 只在首次出现时恢复一次；`didRestoreWorkspace` 防重复（视图可能重建）。
    func restoreWorkspaceIfNeeded(root: URL) {
        guard !didRestoreWorkspace, let workspaceFileURL else { return }
        didRestoreWorkspace = true
        guard let snapshot = TerminalWorkspaceStore.load(from: workspaceFileURL) else { return }

        for tab in snapshot.tabs {
            // 被手改坏的条目直接跳过：宁可少恢复一个标签，也不把坏参数喂给 ssh。
            guard let target = tab.target else { continue }
            addSSHSession(target: target,
                          label: tab.label,
                          root: root,
                          remoteDirectory: tab.remoteDirectory,
                          activate: false)
        }
        persistWorkspace()
    }

    /// 把当前 SSH 标签写盘。本地会话不入档（它一定存在）。
    private func persistWorkspace() {
        guard let workspaceFileURL else { return }
        let tabs = sessions.compactMap { session -> StoredTerminalTab? in
            guard session.kind == .ssh, let target = session.sshTarget else { return nil }
            return StoredTerminalTab(label: session.label,
                                     target: target,
                                     remoteDirectory: session.remoteWorkingDirectory)
        }
        TerminalWorkspaceStore.save(.init(tabs: tabs), to: workspaceFileURL)
    }

    /// 关闭会话（本地会话不允许关闭：它是 agent 的默认执行平面）。
    func close(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].kind == .ssh else { return }
        let closing = sessions.remove(at: index)
        if activeSessionID == id {
            let next = sessions[min(index, sessions.count - 1)]
            activeSessionID = next.id
            observeActive()
        }
        closing.terminate()
        persistWorkspace()
    }

    /// 选中会话的展示名（菜单/状态栏用）。
    var activeLabel: String { activeSession.label }

    // MARK: - 键盘层（⌘1…⌘9 / ⌘⇧[ ⌘⇧] / ⌘W）

    /// ⌘1…⌘9 的落点：按标签顺序激活（1 = 第一个）。0-based。
    ///
    /// 越界是 no-op 而不是崩：菜单项按会话数禁用，但键位可能在
    /// 「刚关掉一个标签」的同一拍里打进来。
    func activateTab(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        activate(sessions[index].id)
    }

    /// ⌘⇧[ / ⌘⇧]：循环切换。
    ///
    /// 为什么不是 ⌃Tab：SwiftTerm 的 `keyDown` 只在**带 Command** 时
    /// 才把键问一次宿主菜单（`MacTerminalView.swift:2055`），⌃Tab 会被
    /// 直接发给 shell —— 菜单项形同虚设。带 ⌘ 的键才走得通。
    func cycleTab(forward: Bool) {
        let current = sessions.firstIndex { $0.id == activeSessionID } ?? 0
        guard let next = Self.nextTabIndex(current: current,
                                           count: sessions.count,
                                           forward: forward) else { return }
        activate(sessions[next].id)
    }

    /// 环形步进的纯函数（单测直接打这里，不依赖 PTY）。
    /// 只有一个标签时返回 nil —— 单标签下「下一个」没有意义，不该产生任何动作。
    static func nextTabIndex(current: Int, count: Int, forward: Bool) -> Int? {
        guard count > 1, current >= 0, current < count else { return nil }
        let step = forward ? 1 : -1
        return (current + step + count) % count
    }

    /// ⌘W：只关 SSH 标签。
    ///
    /// 返回 false = 没关（只剩本地会话）。菜单据此把 ⌘W 让回系统的
    /// 「关闭窗口」——本地 shell 是 agent 的默认执行平面，关掉它无路可走。
    @discardableResult
    func closeActiveTabIfPossible() -> Bool {
        guard hasActiveRemoteSession else { return false }
        close(activeSessionID)
        return true
    }
}

// MARK: - agent 的执行平面

/// MCP `run_in_terminal` 的注入目标是**当时的活跃会话**。
///
/// 语义说明：agent 的 workspace 始终是本地路径，SSH 会话只是"执行通道"
/// （命令在远端跑，文件工具仍作用于本地）。审批卡上的目标标注是这条约束
/// 的用户可见面——不标注等于让用户在不知情的情况下把命令发到远程机器。
extension SessionManager: TerminalCommandExecutor {
    var isTerminalReady: Bool { activeSession.isTerminalReady }
    var isCapturingCommand: Bool { activeSession.isCapturingCommand }
    var commandTargetDescription: String { activeSession.commandTargetDescription }
    var commandExecutionTarget: CommandExecutionTarget { activeSession.commandExecutionTarget }

    func runCommandCaptured(_ command: String, onCapture: @escaping @MainActor (String) -> Void) {
        activeSession.runCommandCaptured(command, onCapture: onCapture)
    }
}
