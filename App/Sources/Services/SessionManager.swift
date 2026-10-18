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

    private init() {
        // 本地会话由 TerminalSession.shared 提供（Scene 菜单在列表出现前就引用它）。
        let local = TerminalSession.shared
        sessions = [local]
        activeSessionID = local.id
        observeActive()
    }

    /// 测试专用：用独立实例构建，避免污染进程级单例的会话列表。
    init(local: TerminalSession) {
        sessions = [local]
        activeSessionID = local.id
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
    @discardableResult
    func openSSHSession(target: SSHTarget, label: String, root: URL) -> TerminalSession {
        let session = TerminalSession(kind: .ssh, label: label, sshTarget: target)
        sessions.append(session)
        activeSessionID = session.id
        observeActive()
        session.start(root: root)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            self?.activeSession.focusTerminal()
        }
        return session
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
    }

    /// 选中会话的展示名（菜单/状态栏用）。
    var activeLabel: String { activeSession.label }
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

    func runCommandCaptured(_ command: String, onCapture: @escaping @MainActor (String) -> Void) {
        activeSession.runCommandCaptured(command, onCapture: onCapture)
    }
}
