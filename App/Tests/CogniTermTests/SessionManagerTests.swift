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
}
