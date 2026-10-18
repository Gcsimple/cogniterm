import XCTest
@testable import TerminalCore

final class SSHTargetTests: XCTestCase {

    // MARK: - 校验

    func testPlainHostIsValid() {
        let target = SSHTarget(host: "example.com")
        XCTAssertTrue(target.isValid)
        XCTAssertEqual(target.port, 22)
        XCTAssertEqual(target.displayName, "example.com")
    }

    func testDisplayNameIncludesUser() {
        XCTAssertEqual(SSHTarget(host: "10.0.0.5", username: "root").displayName,
                       "root@10.0.0.5")
    }

    func testEmptyHostIsRejected() {
        XCTAssertFalse(SSHTarget(host: "   ").isValid)
        XCTAssertFalse(SSHTarget(host: "").isValid)
    }

    /// 选项注入：前导 `-` 会被 ssh 当成选项（`-oProxyCommand=` 是本地命令执行）。
    func testLeadingDashHostIsRejected() {
        let errors = SSHTarget(host: "-oProxyCommand=open -a Calculator").validationErrors()
        XCTAssertFalse(errors.isEmpty)
    }

    func testWhitespaceInHostIsRejected() {
        XCTAssertFalse(SSHTarget(host: "my host").isValid)
        XCTAssertFalse(SSHTarget(host: "host\nhere").isValid)
    }

    func testPortBounds() {
        XCTAssertFalse(SSHTarget(host: "h", port: 0).isValid)
        XCTAssertFalse(SSHTarget(host: "h", port: -1).isValid)
        XCTAssertFalse(SSHTarget(host: "h", port: 65536).isValid)
        XCTAssertTrue(SSHTarget(host: "h", port: 1).isValid)
        XCTAssertTrue(SSHTarget(host: "h", port: 65535).isValid)
    }

    func testUsernameRules() {
        XCTAssertFalse(SSHTarget(host: "h", username: "a b").isValid)
        XCTAssertFalse(SSHTarget(host: "h", username: "-root").isValid)
        XCTAssertFalse(SSHTarget(host: "h", username: "a@b").isValid)
        XCTAssertTrue(SSHTarget(host: "h", username: "deploy_bot").isValid)
    }

    func testJumpHostRules() {
        XCTAssertTrue(SSHTarget(host: "h", jumpHost: "deploy@bastion:2222").isValid)
        XCTAssertFalse(SSHTarget(host: "h", jumpHost: "-J evil").isValid)
        XCTAssertFalse(SSHTarget(host: "h", jumpHost: "a b").isValid)
    }

    func testTildeExpansion() {
        XCTAssertEqual(SSHTarget.expandTilde("~", home: "/Users/x"), "/Users/x")
        XCTAssertEqual(SSHTarget.expandTilde("~/.ssh/id_ed25519", home: "/Users/x"),
                       "/Users/x/.ssh/id_ed25519")
        XCTAssertEqual(SSHTarget.expandTilde("/abs/key", home: "/Users/x"), "/abs/key")
        XCTAssertEqual(SSHTarget.expandTilde("relative/key", home: "/Users/x"), "relative/key")
    }

    // MARK: - 参数组装

    /// 默认配置：不带 -p / -l / -i / -J，目标在最后，外加固定保活参数。
    func testMinimalTargetAssemblesOnlyKeepaliveAndDestination() {
        let profile = TerminalProfile.ssh(SSHTarget(host: "example.com"), base: [:])
        XCTAssertEqual(profile.executablePath, "/usr/bin/ssh")
        XCTAssertEqual(profile.arguments.suffix(1), ["example.com"])
        XCTAssertEqual(profile.arguments.filter { $0 == "-p" }.count, 0)
        XCTAssertEqual(profile.arguments.filter { $0 == "-l" }.count, 0)
        XCTAssertEqual(profile.arguments.filter { $0 == "-i" }.count, 0)
        XCTAssertEqual(profile.arguments.filter { $0 == "-J" }.count, 0)
        XCTAssertTrue(profile.arguments.contains("ConnectTimeout=15"))
        XCTAssertTrue(profile.arguments.contains("ServerAliveInterval=30"))
    }

    func testFullTargetAssemblesAllOptionsInOrder() {
        let target = SSHTarget(host: "example.com",
                               port: 2222,
                               username: "deploy",
                               identityFilePath: "~/.ssh/id_ed25519",
                               jumpHost: "ops@bastion")
        let profile = TerminalProfile.ssh(target, base: [:], programName: "CogniTerm")
        let args = profile.arguments

        // 目标永远在最后（ssh 把最后一个非选项参数当 destination）。
        XCTAssertEqual(args.last, "example.com")
        // 用户 → 端口 → 私钥 → 跳板 的相对顺序固定（可读性与测试稳定性）。
        let userIdx = try! XCTUnwrap(args.firstIndex(of: "-l"))
        let portIdx = try! XCTUnwrap(args.firstIndex(of: "-p"))
        let keyIdx = try! XCTUnwrap(args.firstIndex(of: "-i"))
        let jumpIdx = try! XCTUnwrap(args.firstIndex(of: "-J"))
        XCTAssertLessThan(userIdx, portIdx)
        XCTAssertLessThan(portIdx, keyIdx)
        XCTAssertLessThan(keyIdx, jumpIdx)
        XCTAssertEqual(args[userIdx + 1], "deploy")
        XCTAssertEqual(args[portIdx + 1], "2222")
        XCTAssertEqual(args[keyIdx + 1], NSHomeDirectory() + "/.ssh/id_ed25519")
        XCTAssertEqual(args[jumpIdx + 1], "ops@bastion")
        // 终端语义仍在（远端才能正确渲染颜色与 Unicode）。
        XCTAssertEqual(profile.environment["TERM"], TerminalProfile.defaultTerm)
        XCTAssertEqual(profile.environment["TERM_PROGRAM"], "CogniTerm")
    }

    func testDefaultPortOmitsPortFlag() {
        let profile = TerminalProfile.ssh(SSHTarget(host: "h", port: 22), base: [:])
        XCTAssertFalse(profile.arguments.contains("-p"))
    }

    // MARK: - 真进程（PTY + 系统 ssh）

    /// 真的 exec 一次 `/usr/bin/ssh`，走**生产同款** PTY 管线。
    ///
    /// 为什么值得一条真进程测试：`TerminalProfile.ssh` 的产物只是一组 argv，
    /// 「SSH 会话能不能起」最终取决于 PTY 是否接受任意可执行文件、ssh 是否认这组
    /// 参数。这两件事任何一件不成立，单测全绿也没用。
    ///
    /// 目标选本机一个几乎必然关闭的高位端口：连接被立刻拒绝，不会卡在密码提示上。
    /// 断言落在 ssh 自己的错误文本上——只有真跑起来了才会说出 "Connection refused"。
    func testSSHProfileActuallyDrivesRealSSHProcess() {
        let pty = PseudoTerminal()
        let output = NSMutableData()
        let exited = expectation(description: "ssh 退出")

        pty.onOutput = { chunk in output.append(chunk) }
        pty.onExit = { _ in exited.fulfill() }

        let profile = TerminalProfile.ssh(
            SSHTarget(host: "127.0.0.1", port: 65021, username: "cogniterm-probe"),
            base: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        )
        XCTAssertEqual(profile.executablePath, "/usr/bin/ssh")

        // 走生产同款转换（`ptyConfig`），不是手工拼 Config：
        // 要验证的就是「Profile → PTY」这一段没掉东西。
        XCTAssertNoThrow(try pty.launch(profile.ptyConfig(
            workingDirectory: URL(fileURLWithPath: NSHomeDirectory()),
            columns: 100,
            rows: 40
        )))
        wait(for: [exited], timeout: 20)

        let text = String(data: output as Data, encoding: .utf8) ?? ""
        XCTAssertTrue(
            text.contains("Connection refused") || text.contains("Operation timed out"),
            "ssh 应连不上并报错，实际输出：\(text.debugDescription)"
        )
        XCTAssertFalse(pty.isRunning)
    }
}
