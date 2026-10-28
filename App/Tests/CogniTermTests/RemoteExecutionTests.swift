import XCTest
@testable import CogniTerm
import TerminalCore

/// 「命令实际跑在哪个环境」这条线的回归。
///
/// 这一组的共同背景：`workspaceRoot` 同时是 agent 的**本地**文件域与 sidecar
/// 沙箱边界，SSH 会话只换了执行通道。所以「远程执行目录」必须是独立的一份状态，
/// 且它必须能一路走到审批卡与 agent 的工具结果里——断了任何一段，模型就会把
/// 远端 `ls` 的结果当成本地内容继续推理。
@MainActor
final class RemoteExecutionTests: XCTestCase {

    private var target: SSHTarget {
        SSHTarget(host: "10.0.0.5", port: 2222, username: "deploy")
    }

    private func makeSSH(remoteDirectory: String? = nil) -> TerminalSession {
        TerminalSession(kind: .ssh,
                        label: "deploy@10.0.0.5",
                        sshTarget: target,
                        remoteDirectory: remoteDirectory)
    }

    // MARK: - 执行目标

    func testSSHExecutionTargetCarriesRemoteDirectory() {
        let execution = makeSSH(remoteDirectory: "/srv/app").commandExecutionTarget
        XCTAssertTrue(execution.isRemote)
        XCTAssertEqual(execution.label, "deploy@10.0.0.5")
        XCTAssertEqual(execution.directory, "/srv/app")
        XCTAssertEqual(execution.summary, "deploy@10.0.0.5:/srv/app")
    }

    /// 没指定远程目录时，摘要显示 `~`（远程登录目录），而不是留一个空字符串
    /// 让人以为"不知道在哪"。
    func testSSHExecutionTargetFallsBackToTildeInSummary() {
        let execution = makeSSH().commandExecutionTarget
        XCTAssertTrue(execution.isRemote)
        XCTAssertNil(execution.directory)
        XCTAssertEqual(execution.summary, "deploy@10.0.0.5:~")
    }

    /// 本地会话的 directory 仍然是工作区根——这条不能因为加了远程目录而改变。
    func testLocalExecutionTargetUsesWorkspaceRoot() {
        let session = TerminalSession(kind: .local, label: "本地")
        session.start(root: URL(fileURLWithPath: "/tmp/ws"))
        let execution = session.commandExecutionTarget
        XCTAssertFalse(execution.isRemote)
        XCTAssertEqual(execution.directory, "/tmp/ws")
    }

    // MARK: - 设定远程目录

    func testSetRemoteDirectoryDefersShellSyncWhenPTYNotReady() {
        let session = makeSSH()
        var changes = 0
        session.onRemoteDirectoryChanged = { changes += 1 }

        session.setRemoteWorkingDirectory("/opt/app")
        XCTAssertEqual(session.remoteWorkingDirectory, "/opt/app")
        XCTAssertEqual(changes, 1)
        // PTY 没起来：不往终端里打字，但留下一个可见的待办（同步按钮高亮）。
        XCTAssertEqual(session.pendingRemoteDirectorySync, "/opt/app")

        // 同值不重复通知：每次点「用这个目录」都重写现场文件没有意义。
        session.setRemoteWorkingDirectory("/opt/app")
        XCTAssertEqual(changes, 1)
    }

    func testClearingRemoteDirectoryAlsoClearsPending() {
        let session = makeSSH(remoteDirectory: "/opt/app")
        session.setRemoteWorkingDirectory("/opt/app")
        XCTAssertNotNil(session.pendingRemoteDirectorySync)

        session.setRemoteWorkingDirectory(nil)
        XCTAssertNil(session.remoteWorkingDirectory)
        XCTAssertNil(session.pendingRemoteDirectorySync)
    }

    /// 本地会话不认这个设置：本地目录由工作区管，两套状态不能互相污染。
    func testLocalSessionIgnoresRemoteDirectory() {
        let session = TerminalSession(kind: .local, label: "本地")
        session.setRemoteWorkingDirectory("/opt/app")
        XCTAssertNil(session.remoteWorkingDirectory)
    }

    /// 重连后远端 shell 回到登录目录，而设定的执行目录还在 → 必须亮出待办，
    /// 否则「agent 在 /opt/app、终端在 ~」这个错位会静默发生。
    func testRestartMarksRemoteDirectoryForResync() {
        let session = makeSSH(remoteDirectory: "/opt/app")
        session.restart()
        XCTAssertEqual(session.pendingRemoteDirectorySync, "/opt/app")
    }

    // MARK: - agent 可见的结果标注

    /// 远程结果必须带 [执行环境] 抬头，本地不必（本地是默认情况，加了只是噪音）。
    func testAnnotateAddsContextOnlyForRemote() {
        let local = CommandExecutionTarget(label: "本地", directory: "/tmp/ws", isRemote: false)
        XCTAssertEqual(TerminalMCP.annotateExecution("a\nb", for: local), "a\nb")

        let remote = CommandExecutionTarget(label: "deploy@box",
                                            directory: "/opt/app",
                                            isRemote: true)
        let text = TerminalMCP.annotateExecution("total 0", for: remote)
        XCTAssertTrue(text.contains("远程主机 deploy@box"))
        XCTAssertTrue(text.contains("/opt/app"))
        XCTAssertTrue(text.contains("文件工具"))
        XCTAssertTrue(text.hasSuffix("total 0"), "原始输出必须完整保留在末尾")
    }

    /// 目录未知时标注要说清是「远程登录目录」，不能让模型以为"目录是空的"。
    func testAnnotateNamesUnknownRemoteDirectory() {
        let remote = CommandExecutionTarget(label: "box", directory: nil, isRemote: true)
        XCTAssertTrue(TerminalMCP.annotateExecution("x", for: remote).contains("未指定"))
    }
}
