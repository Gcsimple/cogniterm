import XCTest
@testable import CogniTerm
import TerminalCore

/// 会话集合与 agent 执行平面委托的回归。
///
/// 用 `SessionManager(local:)` 而非单例：测试会开关会话，不能污染进程级列表。
@MainActor
final class SessionManagerTests: XCTestCase {

    private func makeManager() -> SessionManager {
        let local = TerminalSession(kind: .local, label: "本地")
        return SessionManager(local: local)
    }

    private var target: SSHTarget {
        SSHTarget(host: "10.0.0.5", port: 2222, username: "deploy")
    }

    func testInitialStateHasOnlyLocalSessionActivated() {
        let manager = makeManager()
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.activeSession.kind, .local)
        XCTAssertEqual(manager.activeSession.label, "本地")
        XCTAssertFalse(manager.hasActiveRemoteSession)
    }

    func testOpenSSHAppendsSessionAndActivatesIt() {
        let manager = makeManager()
        let ssh = manager.openSSHSession(target: target,
                                         label: "deploy@10.0.0.5",
                                         root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(manager.activeSessionID, ssh.id)
        XCTAssertTrue(manager.hasActiveRemoteSession)
        XCTAssertEqual(ssh.kind, .ssh)
        XCTAssertEqual(ssh.label, "deploy@10.0.0.5")
        XCTAssertEqual(ssh.sshTarget, target)
    }

    func testActivateSwitchesBackToLocal() {
        let manager = makeManager()
        let ssh = manager.openSSHSession(target: target, label: "box",
                                         root: FileManager.default.homeDirectoryForCurrentUser)
        manager.activate(manager.sessions[0].id)
        XCTAssertEqual(manager.activeSession.kind, .local)
        // 非法 id 不改变状态。
        manager.activate(ssh.id)
        manager.activate(UUID())
        XCTAssertEqual(manager.activeSessionID, ssh.id)
    }

    func testCloseSSHFallsBackToLocalAndRemovesSession() {
        let manager = makeManager()
        let ssh = manager.openSSHSession(target: target, label: "box",
                                         root: FileManager.default.homeDirectoryForCurrentUser)
        manager.close(ssh.id)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.activeSession.kind, .local)
        XCTAssertFalse(manager.hasActiveRemoteSession)
    }

    func testLocalSessionIsNotClosable() {
        let manager = makeManager()
        let localID = manager.sessions[0].id
        manager.close(localID)
        XCTAssertEqual(manager.sessions.count, 1, "本地会话是 agent 的默认执行平面，不允许关闭")
    }

    // MARK: - executor 委托

    /// agent 的执行平面指向「当时的活跃会话」：
    /// 切到 SSH 后，目标标注与就绪度都跟着变。
    func testExecutorDelegatesToActiveSession() {
        let manager = makeManager()
        // 本地会话未 start / 未 attach → PTY 未就绪。
        XCTAssertFalse(manager.isTerminalReady)
        XCTAssertEqual(manager.commandTargetDescription, "本地")

        manager.openSSHSession(target: target, label: "deploy@10.0.0.5",
                               root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(manager.commandTargetDescription, "deploy@10.0.0.5")

        manager.activate(manager.sessions[0].id)
        XCTAssertEqual(manager.commandTargetDescription, "本地")
    }

    /// 命令注入落在活跃会话上：未就绪时回调立刻收到空输出（fail-fast），
    /// 不会挂住 MCP 队列。
    func testRunCommandCapturedFailsFastWhenActiveSessionNotReady() {
        let manager = makeManager()
        var captured: String?
        manager.runCommandCaptured("ls") { captured = $0 }
        XCTAssertEqual(captured, "")
    }

    // MARK: - 终端现场（上次开着哪些机器）

    private func makePersistingManager(at url: URL) -> SessionManager {
        SessionManager(local: TerminalSession(kind: .local, label: "本地"), workspaceFileURL: url)
    }

    private func tempWorkspaceFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-workspace-\(UUID().uuidString).json")
    }

    /// 现场 = SSH 标签组合；本地会话不入档（它永远存在）。
    func testOpenSSHPersistsSnapshotWithoutLocalSession() throws {
        let url = tempWorkspaceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = makePersistingManager(at: url)
        manager.openSSHSession(target: target, label: "deploy@10.0.0.5",
                               root: FileManager.default.homeDirectoryForCurrentUser)

        let snapshot = try XCTUnwrap(TerminalWorkspaceStore.load(from: url))
        XCTAssertEqual(snapshot.tabs.count, 1, "本地会话不该被写进现场")
        XCTAssertEqual(snapshot.tabs.first?.label, "deploy@10.0.0.5")
        XCTAssertEqual(snapshot.tabs.first?.host, "10.0.0.5")
        XCTAssertEqual(snapshot.tabs.first?.port, 2222)
        XCTAssertEqual(snapshot.tabs.first?.username, "deploy")
    }

    /// 启动时恢复标签，且**只恢复一次**——视图重建会重复调用，
    /// 没有这个幂等性就会开出一串重复标签。
    func testRestoreRebuildsSSHTabsAndIsIdempotent() throws {
        let url = tempWorkspaceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        TerminalWorkspaceStore.save(.init(tabs: [
            StoredTerminalTab(label: "a@box", target: SSHTarget(host: "box", username: "a")),
            StoredTerminalTab(label: "b@db", target: SSHTarget(host: "db", port: 2200, username: "b")),
        ]), to: url)

        let manager = makePersistingManager(at: url)
        manager.restoreWorkspaceIfNeeded(root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(manager.sessions.count, 3, "本地 + 两个恢复出来的远程标签")
        XCTAssertEqual(manager.sessions.filter { $0.kind == .ssh }.map(\.label).sorted(),
                       ["a@box", "b@db"])
        XCTAssertEqual(manager.activeSession.kind, .local,
                       "恢复现场不能抢焦点：用户打开 app 应该停在本地 shell")

        manager.restoreWorkspaceIfNeeded(root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(manager.sessions.count, 3, "第二次调用必须无副作用")
    }

    /// 关掉一个标签要同步落盘，否则下次启动会把它变戏法变回来。
    func testClosingTabUpdatesSnapshot() throws {
        let url = tempWorkspaceFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = makePersistingManager(at: url)
        let ssh = manager.openSSHSession(target: target, label: "deploy@10.0.0.5",
                                         root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(TerminalWorkspaceStore.load(from: url)?.tabs.count, 1)

        manager.close(ssh.id)
        XCTAssertEqual(TerminalWorkspaceStore.load(from: url)?.tabs.count, 0)
    }

    /// 没有落盘路径的实例（测试默认构造）不写任何文件——
    /// 否则跑一次测试就把用户上次的现场覆盖了。
    func testInMemoryManagerNeverWritesSnapshot() {
        let manager = makeManager()
        manager.openSSHSession(target: target, label: "x@y",
                               root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertEqual(manager.sessions.count, 2)
        // 无法断言"没写默认路径"（那会读写真实配置文件），
        // 但 canStart 之外没有任何路径能绕过 workspaceFileURL == nil 的守卫：
        // persistWorkspace() 的第一行就是 guard。
    }

    /// 坏条目（被人手改成非法 host / 端口）必须被跳过，而不是喂给 ssh。
    func testStoredTabWithIllegalTargetIsRejected() {
        let bad = StoredTerminalTab(label: "bad", target: SSHTarget(host: "ok"))
        var mutated = bad
        mutated.host = "-oProxyCommand=/bin/sh"
        XCTAssertNil(mutated.target, "前导 - 会被 ssh 当成选项，必须拒绝")

        var badPort = bad
        badPort.port = 70000
        XCTAssertNil(badPort.target)

        XCTAssertNotNil(bad.target)
    }

    // MARK: - 键盘层（⌘1…⌘9 / ⌘⇧[ ⌘⇧] / ⌘W）

    /// 环形步进：首尾相接，两个方向都要跨过边界。
    func testNextTabIndexWrapsAround() {
        XCTAssertEqual(SessionManager.nextTabIndex(current: 0, count: 3, forward: true), 1)
        XCTAssertEqual(SessionManager.nextTabIndex(current: 2, count: 3, forward: true), 0)
        XCTAssertEqual(SessionManager.nextTabIndex(current: 0, count: 3, forward: false), 2)
        XCTAssertEqual(SessionManager.nextTabIndex(current: 1, count: 3, forward: false), 0)
    }

    /// 单标签下「下一个」不该产生动作，越界参数也不该把索引算到负值。
    func testNextTabIndexRefusesDegenerateInput() {
        XCTAssertNil(SessionManager.nextTabIndex(current: 0, count: 1, forward: true))
        XCTAssertNil(SessionManager.nextTabIndex(current: 5, count: 3, forward: true))
        XCTAssertNil(SessionManager.nextTabIndex(current: -1, count: 3, forward: true))
    }

    func testActivateTabIgnoresOutOfRangeAndSwitchesByPosition() {
        let manager = makeManager()
        let ssh = manager.openSSHSession(target: target, label: "box",
                                         root: FileManager.default.homeDirectoryForCurrentUser)

        manager.activateTab(at: 0)
        XCTAssertEqual(manager.activeSession.kind, .local, "⌘1 = 第一个标签 = 本地")

        manager.activateTab(at: 1)
        XCTAssertEqual(manager.activeSessionID, ssh.id, "⌘2 = 第二个标签")

        // 越界：旧实现会 index out of range 崩掉，现在必须是 no-op。
        manager.activateTab(at: 9)
        XCTAssertEqual(manager.activeSessionID, ssh.id)
    }

    func testCycleTabMovesThroughSessionsAndStopsWhenAlone() {
        let manager = makeManager()
        manager.cycleTab(forward: true)
        XCTAssertEqual(manager.activeSession.kind, .local, "只有一个标签时不动")

        let ssh = manager.openSSHSession(target: target, label: "box",
                                         root: FileManager.default.homeDirectoryForCurrentUser)
        manager.activateTab(at: 0)
        manager.cycleTab(forward: true)
        XCTAssertEqual(manager.activeSessionID, ssh.id)
        manager.cycleTab(forward: true)
        XCTAssertEqual(manager.activeSession.kind, .local, "⌘⇧] 从最后一个绕回第一个")
    }

    /// ⌘W 的语义：只关 SSH。返回 false 时菜单把键让回系统「关闭窗口」。
    func testCloseActiveTabOnlyClosesRemoteSessions() {
        let manager = makeManager()
        XCTAssertFalse(manager.closeActiveTabIfPossible(),
                       "只剩本地会话 → 不关任何东西，⌘W 应该落回关闭窗口")

        manager.openSSHSession(target: target, label: "box",
                               root: FileManager.default.homeDirectoryForCurrentUser)
        XCTAssertTrue(manager.closeActiveTabIfPossible())
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.activeSession.kind, .local)
    }
}
