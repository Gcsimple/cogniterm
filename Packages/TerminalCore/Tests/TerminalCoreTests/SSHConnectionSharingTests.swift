import XCTest
@testable import TerminalCore

final class SSHConnectionSharingTests: XCTestCase {

    private var target: SSHTarget {
        SSHTarget(host: "10.0.0.5", port: 2222, username: "deploy")
    }

    /// 名字必须**跨进程稳定**：`hashValue` 每进程加盐，用它做 socket 名
    /// 会导致重启后找不到旧 socket，复用静默失效。
    func testSocketNameIsStableAndDistinct() {
        let a = SSHConnectionSharing.socketName(for: target)
        let b = SSHConnectionSharing.socketName(for: target)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("ct-"))
        XCTAssertEqual(a.count, 3 + 16)

        // 换端口 / 换用户 = 另一条通道（不同账号的已认证 session 不能复用）。
        XCTAssertNotEqual(a, SSHConnectionSharing.socketName(
            for: SSHTarget(host: "10.0.0.5", port: 22, username: "deploy")))
        XCTAssertNotEqual(a, SSHConnectionSharing.socketName(
            for: SSHTarget(host: "10.0.0.5", port: 2222, username: "root")))
        XCTAssertNotEqual(a, SSHConnectionSharing.socketName(
            for: SSHTarget(host: "10.0.0.6", port: 2222, username: "deploy")))
    }

    /// 已知输入的摘要值：钉死实现，防止哪天顺手换成 `Hasher`（那是随机的）。
    func testIdentityKeyAndDigestArePinned() {
        XCTAssertEqual(SSHConnectionSharing.identityKey(for: target), "deploy@10.0.0.5:2222")
        XCTAssertEqual(SSHConnectionSharing.hexDigest("deploy@10.0.0.5:2222"),
                       SSHConnectionSharing.hexDigest("deploy@10.0.0.5:2222"))
        // 长度固定 16 位十六进制，不随输入长度变化。
        XCTAssertEqual(SSHConnectionSharing.hexDigest("a").count, 16)
        XCTAssertEqual(SSHConnectionSharing.hexDigest(String(repeating: "x", count: 500)).count, 16)
    }

    func testSocketPathTrimsTrailingSlash() {
        let path = SSHConnectionSharing.socketPath(for: target, directory: "/tmp/ct-control/")
        XCTAssertEqual(path, "/tmp/ct-control/" + SSHConnectionSharing.socketName(for: target))
    }

    /// 超长路径返回 nil（调用方据此**不启用复用**）。截断是绝对不能做的：
    /// 两个不同目标撞到同一个 socket，等于把命令发到别的机器上。
    func testSocketPathRefusesOverlongDirectory() {
        let deep = "/tmp/" + String(repeating: "x", count: 200)
        XCTAssertNil(SSHConnectionSharing.socketPath(for: target, directory: deep))
    }

    // MARK: - argv 组装

    func testControlSocketAddsMultiplexingOptions() {
        let profile = TerminalProfile.ssh(target,
                                          controlSocketPath: "/tmp/ct-control/ct-abc",
                                          base: [:])
        let args = profile.arguments
        XCTAssertTrue(args.contains("ControlMaster=auto"))
        XCTAssertTrue(args.contains("ControlPath=/tmp/ct-control/ct-abc"))
        XCTAssertTrue(args.contains("ControlPersist=600"))
        // 复用选项必须在 destination 之前，否则 ssh 会把它当远程命令。
        let hostIndex = try! XCTUnwrap(args.firstIndex(of: "10.0.0.5"))
        let persistIndex = try! XCTUnwrap(args.firstIndex(of: "ControlPersist=600"))
        XCTAssertLessThan(persistIndex, hostIndex)
    }

    func testNoControlSocketMeansNoMultiplexing() {
        let args = TerminalProfile.ssh(target, base: [:]).arguments
        XCTAssertFalse(args.contains { $0.hasPrefix("ControlMaster") })
        XCTAssertFalse(args.contains { $0.hasPrefix("ControlPath") })
    }

    /// 一次性命令默认**不参与**复用（没有 socket 参数时）：它连完就退出。
    /// 但给了 socket 时必须挂成从通道——否则"存了密码"的用户点目录浏览会
    /// 拿不到身份（探测走 BatchMode，自己不会认证）。
    func testExecOnlyReusesWhenGivenSocket() {
        let plain = TerminalProfile.sshExec(target, remoteCommand: "pwd", base: [:]).arguments
        XCTAssertFalse(plain.contains { $0.hasPrefix("ControlMaster") })
        XCTAssertFalse(plain.contains { $0.hasPrefix("ControlPath") })

        let shared = TerminalProfile.sshExec(target,
                                             remoteCommand: "pwd",
                                             controlSocketPath: "/tmp/ct/ct-abc",
                                             base: [:]).arguments
        // 必须是 `no`：探测不该自己变成 master（那会把一次性进程变成常驻连接）。
        XCTAssertTrue(shared.contains("ControlMaster=no"))
        XCTAssertTrue(shared.contains("ControlPath=/tmp/ct/ct-abc"))
        // 从通道也在 destination 之前。
        let hostIndex = try! XCTUnwrap(shared.firstIndex(of: "10.0.0.5"))
        let pathIndex = try! XCTUnwrap(shared.firstIndex(of: "ControlPath=/tmp/ct/ct-abc"))
        XCTAssertLessThan(pathIndex, hostIndex)
    }
}

final class PasswordPromptDetectorTests: XCTestCase {

    private func feed(_ chunks: [String]) -> Bool {
        var detector = PasswordPromptDetector()
        var last = false
        for chunk in chunks {
            last = detector.feed(Data(chunk.utf8))
        }
        return last
    }

    func testRecognisesOpenSSHPrompt() {
        XCTAssertTrue(feed(["deploy@10.0.0.5's password: "]))
        XCTAssertTrue(feed(["deploy@10.0.0.5's password:"]))
        // ssh 用 \r 把提示刷回行首。
        XCTAssertTrue(feed(["deploy@10.0.0.5's password: \r"]))
    }

    func testRecognisesPasswordForForm() {
        XCTAssertTrue(feed(["Password for deploy@10.0.0.5: "]))
    }

    /// 提示被切成两块到达（PTY 读经常这样）也必须认出来——否则就是个
    /// 「时好时坏」的自动填充，比没有更糟。
    func testRecognisesPromptSplitAcrossChunks() {
        XCTAssertTrue(feed(["deploy@10.0.0.5's pass", "word: "]))
    }

    /// 泛化的 `password:` **故意不匹配**：`cat` 一个含该字样的文件也会命中，
    /// 那一刻填密码会把明文打进终端历史。
    func testIgnoresUnrelatedPasswordText() {
        XCTAssertFalse(feed(["notes.txt: db password: "]))
        XCTAssertFalse(feed(["echo password: hello"]))
    }

    /// 提示后面又出现了别的输出（比如密码错、认证失败）就不该再填。
    func testStopsMatchingOnceOutputMovesOn() {
        XCTAssertFalse(feed(["deploy@10.0.0.5's password: \r\nPermission denied, please try again.\r\n"]))
    }

    func testIgnoresHostKeyQuestion() {
        XCTAssertFalse(feed(["Are you sure you want to continue connecting (yes/no/[fingerprint])? "]))
    }

    func testEmptyFeedIsNotAPrompt() {
        XCTAssertFalse(feed([]))
        XCTAssertFalse(feed(["   "]))
    }

    /// 只会保留末尾一小段：很早以前出现过的 "password:" 不会一直挂着等触发。
    func testOldOutputIsForgotten() {
        var detector = PasswordPromptDetector()
        detector.feed(Data("deploy@host's password: ".utf8))
        XCTAssertTrue(detector.isAtPasswordPrompt)
        detector.feed(Data(String(repeating: "x", count: 600).utf8))
        XCTAssertFalse(detector.isAtPasswordPrompt)
    }

    func testResetClearsDetector() {
        var detector = PasswordPromptDetector()
        detector.feed(Data("deploy@host's password: ".utf8))
        XCTAssertTrue(detector.isAtPasswordPrompt)
        detector.reset()
        XCTAssertFalse(detector.isAtPasswordPrompt)
    }
}
