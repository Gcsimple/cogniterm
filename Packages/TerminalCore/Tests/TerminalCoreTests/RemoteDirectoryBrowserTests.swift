import XCTest
@testable import TerminalCore

final class RemoteDirectoryBrowserTests: XCTestCase {

    // MARK: - 路径表达式（远端 shell 注入防线）

    /// 空格 / 中文 / 引号都必须落在一个 POSIX 单引号块里。
    func testPathExpressionQuotesUnsafeCharacters() {
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/opt/my app"),
                       "'/opt/my app'")
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/data/项目"),
                       "'/data/项目'")
        // it's → 'it'\''s'
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/tmp/it's"),
                       "'/tmp/it'\\''s'")
        // 命令替换与分号只是字面量，不会被远端 shell 执行。
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/tmp/$(rm -rf /)"),
                       "'/tmp/$(rm -rf /)'")
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/tmp/a;ls"),
                       "'/tmp/a;ls'")
    }

    /// `~` 必须留在引号外，否则远端 shell 不会展开它。
    func testTildeStaysUnquoted() {
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("~"), "~")
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression(""), "~")
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("~/proj"), "~/'proj'")
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("~/my proj"), "~/'my proj'")
        // 只处理前导 ~；`a~b` 里的 ~ 是普通字符。
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/tmp/a~b"), "'/tmp/a~b'")
    }

    func testRootPathNeedsNoQuotes() {
        XCTAssertEqual(RemoteDirectoryBrowser.remotePathExpression("/"), "/")
    }

    /// 命令形状本身：cd 失败要短路（否则会在错的目录里 ls 出一屏无关目录）。
    func testListCommandShape() {
        let command = RemoteDirectoryBrowser.listCommand(path: "/opt/app")
        XCTAssertEqual(command, "cd -- '/opt/app' 2>/dev/null && pwd && ls -1Ap")
        XCTAssertTrue(command.contains("&&"), "cd 失败必须短路")
        XCTAssertTrue(RemoteDirectoryBrowser.listCommand(path: "~").contains("cd -- ~ "))
    }

    // MARK: - 输出解析

    func testParseKeepsOnlyDirectories() {
        let output = """
        /home/deploy
        app/
        logs/
        notes.txt
        .bashrc
        deploy.sh
        """
        let listing = RemoteDirectoryBrowser.parse(output)
        XCTAssertEqual(listing?.path, "/home/deploy")
        XCTAssertEqual(listing?.directories, ["app", "logs"])
    }

    /// `ls -1Ap` 不会输出 `.` / `..`（-A 已排除），但输出被手改 / 远端 ls 不同实现时
    /// 仍要挡住，否则选择器里会多出两个点进去没变化的条目。
    func testParseDropsDotEntries() {
        let output = "/srv\n./\n../\napi/\n"
        XCTAssertEqual(RemoteDirectoryBrowser.parse(output)?.directories, ["api"])
    }

    func testParseSortsAndDedupesNothing() {
        let output = "/srv\nzeta/\nalpha/\nMid/\n"
        // 按名称排序（ASCII 序，大写在前），保证每次打开选择器的顺序一致。
        XCTAssertEqual(RemoteDirectoryBrowser.parse(output)?.directories, ["Mid", "alpha", "zeta"])
    }

    /// 首行必须是 pwd（绝对路径）。没有它说明 cd 没成功或输出被污染。
    func testParseRejectsOutputWithoutPwd() {
        XCTAssertNil(RemoteDirectoryBrowser.parse(""))
        XCTAssertNil(RemoteDirectoryBrowser.parse("app/\nlogs/\n"))
        XCTAssertNil(RemoteDirectoryBrowser.parse("~/proj\napp/\n"))
    }

    func testParseEmptyDirectory() {
        let listing = RemoteDirectoryBrowser.parse("/srv/empty\n")
        XCTAssertEqual(listing?.path, "/srv/empty")
        XCTAssertEqual(listing?.directories, [])
    }

    // MARK: - 错误分类

    func testClassifyAuthentication() {
        XCTAssertEqual(
            RemoteDirectoryBrowser.classify(
                stderr: "deploy@host: Permission denied (publickey).",
                exitCode: 255, path: "/opt", stdout: ""),
            .authenticationRequired)
        XCTAssertEqual(
            RemoteDirectoryBrowser.classify(
                stderr: "Host key verification failed.",
                exitCode: 255, path: "/opt", stdout: ""),
            .hostKeyUnknown)
    }

    /// 连上了但 cd 进不去：ssh 退出码是远端给的，不能报成"连不上"。
    func testClassifyUnreadableDirectory() {
        XCTAssertEqual(
            RemoteDirectoryBrowser.classify(stderr: "", exitCode: 1, path: "/nope", stdout: ""),
            .unreadable("/nope"))
    }

    func testClassifyNetwork() {
        if case .unreachable = RemoteDirectoryBrowser.classify(
            stderr: "ssh: connect to host x port 22: Connection refused",
            exitCode: 255, path: "/opt", stdout: "") {
        } else {
            XCTFail("网络错误应归为 unreachable")
        }
    }

    // MARK: - argv 组装

    /// 一次性命令的语义要点：BatchMode（绝不停在密码提示上）、-T（不要 pty）、
    /// destination 在远程命令之前（否则 ssh 会把命令当主机名）。
    func testExecArgumentsShape() {
        let target = SSHTarget(host: "example.com", port: 2222, username: "deploy",
                               identityFilePath: "~/.ssh/id_ed25519")
        let profile = TerminalProfile.sshExec(target, remoteCommand: "pwd", base: [:])
        let args = profile.arguments

        XCTAssertEqual(profile.executablePath, "/usr/bin/ssh")
        XCTAssertEqual(args.last, "pwd", "远程命令必须排在最后")
        let hostIndex = try! XCTUnwrap(args.firstIndex(of: "example.com"))
        XCTAssertEqual(hostIndex, args.count - 2, "destination 紧邻远程命令之前")
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("-T"))
        XCTAssertTrue(args.contains("deploy"))
        XCTAssertTrue(args.contains("2222"))
        // 一次性命令不需要保活（会话级参数），否则会混淆两套语义。
        XCTAssertFalse(args.contains("ServerAliveInterval=30"))
        XCTAssertFalse(args.contains("ServerAliveCountMax=3"))
    }

    func testExecUsesCustomConnectTimeout() {
        let profile = TerminalProfile.sshExec(SSHTarget(host: "h"),
                                              remoteCommand: "pwd",
                                              connectTimeout: 3,
                                              base: [:])
        XCTAssertTrue(profile.arguments.contains("ConnectTimeout=3"))
        XCTAssertEqual(profile.arguments.filter { $0.hasPrefix("ConnectTimeout=") }.count, 1,
                       "不能同时出现两个 ConnectTimeout（ssh 认第一个，语义会变得不可读）")
    }

    // MARK: - 真 ssh 进程

    /// 真跑一次 ssh：证明「一次性命令」这条路在本机可行，且失败被正确分类。
    ///
    /// 目标是一个几乎必然关闭的高位端口：连接被立刻拒绝，不会卡在密码提示上。
    func testListAgainstClosedPortReportsUnreachable() {
        let target = SSHTarget(host: "127.0.0.1", port: 65021, username: "cogniterm-probe")
        XCTAssertThrowsError(
            try RemoteDirectoryBrowser.listSync(target: target, path: "~", timeout: 20)
        ) { error in
            guard case .unreachable = error as? RemoteDirectoryError else {
                return XCTFail("应分类为 unreachable，实际：\(error)")
            }
        }
    }
}

final class RemoteCommandTests: XCTestCase {

    func testNoDirectoryLeavesCommandUntouched() {
        XCTAssertEqual(RemoteCommand.withWorkingDirectory(nil, command: "ls -la"), "ls -la")
        XCTAssertEqual(RemoteCommand.withWorkingDirectory("", command: "ls -la"), "ls -la")
        XCTAssertEqual(RemoteCommand.withWorkingDirectory("   ", command: "ls -la"), "ls -la")
    }

    /// 单行：一个 `cd &&` 前缀，路径引号化，命令原样跟在后面。
    func testSingleLineGetsPrefixed() {
        XCTAssertEqual(
            RemoteCommand.withWorkingDirectory("/opt/my app", command: "git status"),
            "cd -- '/opt/my app' && git status"
        )
    }

    /// `~` 不能被引号包住（否则远端 shell 不展开，cd 一个叫 `~` 的目录）。
    func testTildeDirectoryStaysExpandable() {
        XCTAssertEqual(
            RemoteCommand.withWorkingDirectory("~/proj", command: "ls"),
            "cd -- ~/'proj' && ls"
        )
    }

    /// 多行必须包进子 shell：`cd X && a\nb` 里的 `&&` 只管住第一行，
    /// 后面几行会无条件执行——危险命令恰好长这样。
    func testMultiLineIsWrappedInSubshell() {
        let command = "git add .\nrm -rf build"
        XCTAssertEqual(
            RemoteCommand.withWorkingDirectory("/srv/app", command: command),
            "cd -- '/srv/app' && (\ngit add .\nrm -rf build\n)"
        )
    }
}

