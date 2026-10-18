import XCTest
@testable import TerminalCore

final class TerminalProfileTests: XCTestCase {

    // MARK: - shell 解析

    func testUsesShellFromEnvironmentWhenItIsAKnownExecutable() {
        let path = TerminalProfile.resolveShellPath(
            environment: ["SHELL": "/bin/bash"],
            isExecutable: { _ in true }
        )
        XCTAssertEqual(path, "/bin/bash")
    }

    func testFallsBackWhenShellIsMissing() {
        XCTAssertEqual(
            TerminalProfile.resolveShellPath(environment: [:], isExecutable: { _ in true }),
            "/bin/zsh"
        )
    }

    func testFallsBackWhenShellIsRelative() {
        // 相对路径无法 forkpty，必须回落而不是原样透传。
        XCTAssertEqual(
            TerminalProfile.resolveShellPath(environment: ["SHELL": "zsh"], isExecutable: { _ in true }),
            "/bin/zsh"
        )
    }

    func testFallsBackWhenShellIsNotInWhitelist() {
        XCTAssertEqual(
            TerminalProfile.resolveShellPath(
                environment: ["SHELL": "/usr/local/bin/my-shell-wrapper"],
                isExecutable: { _ in true }
            ),
            "/bin/zsh"
        )
    }

    func testFallsBackWhenShellIsNotExecutable() {
        XCTAssertEqual(
            TerminalProfile.resolveShellPath(
                environment: ["SHELL": "/bin/fish"],
                isExecutable: { _ in false }
            ),
            "/bin/zsh"
        )
    }

    func testWhitelistedShellsKeepTheirPathAndAreStartedAsLoginShells() {
        for name in ["zsh", "bash", "sh", "ksh", "fish"] {
            let path = "/bin/\(name)"
            let profile = TerminalProfile.standard(
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                columns: 80,
                rows: 24,
                base: ["SHELL": path],
                isExecutable: { _ in true }
            )
            XCTAssertEqual(profile.executablePath, path)
            XCTAssertEqual(
                profile.arguments, ["-l", "-i"],
                "\(name) 必须以 login shell 启动，否则 PATH 里没有 Homebrew"
            )
        }
    }

    func testUnknownShellOnlyGetsInteractiveFlag() {
        // dash 不认 -l。
        XCTAssertEqual(TerminalProfile.arguments(forShellAt: "/opt/homebrew/bin/dash"), ["-i"])
    }

    // MARK: - 环境

    func testSanitizeStripsProxyAndDyldVariables() {
        var base = [
            "PATH": "/usr/bin",
            "LANG": "zh_CN.UTF-8",
            "DYLD_INSERT_LIBRARIES": "/evil.dylib",
            "DYLD_FRAMEWORK_PATH": "/evil",
        ]
        for key in TerminalProfile.proxyVariables {
            base[key] = "http://127.0.0.1:59999"
        }

        let sanitized = TerminalProfile.sanitize(base)

        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
        XCTAssertEqual(sanitized["LANG"], "zh_CN.UTF-8")
        for key in TerminalProfile.proxyVariables {
            XCTAssertNil(sanitized[key], "\(key) 必须从子 shell 环境里剔掉")
        }
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["DYLD_FRAMEWORK_PATH"])
    }

    func testEnrichForcesTermButRespectsExplicitLocale() {
        let enriched = TerminalProfile.enrich(["TERM": "screen-256color", "LANG": "zh_CN.UTF-8"])
        XCTAssertEqual(enriched["TERM"], "xterm-256color", "父进程可能跑在 tmux 里，TERM 必须覆盖")
        XCTAssertEqual(enriched["LANG"], "zh_CN.UTF-8", "用户显式设的 locale 不能被覆盖")
        XCTAssertEqual(enriched["COLORTERM"], "truecolor")
    }

    func testEnrichFillsLocaleOnlyWhenAbsent() {
        let filled = TerminalProfile.enrich(["PATH": "/usr/bin"])
        XCTAssertEqual(filled["LANG"], "en_US.UTF-8")
        XCTAssertEqual(filled["TERM"], "xterm-256color")

        // LC_ALL / LC_CTYPE 也算已有 locale，不该再补 LANG。
        let lcAll = TerminalProfile.enrich(["LC_ALL": "C"])
        XCTAssertNil(lcAll["LANG"])
    }

    func testEnrichRecordingProgramIdentity() {
        let enriched = TerminalProfile.enrich(
            [:], programName: "CogniTerm", programVersion: "1.2.3"
        )
        XCTAssertEqual(enriched["TERM_PROGRAM"], "CogniTerm")
        XCTAssertEqual(enriched["TERM_PROGRAM_VERSION"], "1.2.3")
        // 留空时不应该写入空字符串。
        XCTAssertNil(TerminalProfile.enrich([:], programVersion: "")["TERM_PROGRAM_VERSION"])
    }

    func testStandardProfileCombinesResolutionSanitizationAndEnrichment() {
        let profile = TerminalProfile.standard(
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            columns: 120,
            rows: 30,
            base: ["SHELL": "/bin/bash", "HTTPS_PROXY": "http://127.0.0.1:9", "PATH": "/usr/bin"],
            isExecutable: { _ in true },
            programName: "CogniTerm"
        )

        XCTAssertEqual(profile.executablePath, "/bin/bash")
        XCTAssertEqual(profile.arguments, ["-l", "-i"])
        XCTAssertNil(profile.environment["HTTPS_PROXY"])
        XCTAssertEqual(profile.environment["PATH"], "/usr/bin")
        XCTAssertEqual(profile.environment["TERM"], "xterm-256color")
        XCTAssertEqual(profile.environment["TERM_PROGRAM"], "CogniTerm")

        let config = profile.ptyConfig(
            workingDirectory: URL(fileURLWithPath: "/private/tmp"),
            columns: 120, rows: 30
        )
        XCTAssertEqual(config.executablePath, "/bin/bash")
        XCTAssertEqual(config.columns, 120)
        XCTAssertEqual(config.rows, 30)
        XCTAssertEqual(config.workingDirectory?.path, "/private/tmp")
        XCTAssertNil(config.environment?["HTTPS_PROXY"])
    }

    // MARK: - 命令拼装

    func testSingleQuotedWrapsPlainPath() {
        XCTAssertEqual(ShellCommand.singleQuoted("/Users/a/项目"), "'/Users/a/项目'")
    }

    func testSingleQuotedEscapesEmbeddedQuote() {
        // 这是注入面：路径里带单引号时，直接拼接会提前闭合引号。
        XCTAssertEqual(ShellCommand.singleQuoted("/tmp/it's"), "'/tmp/it'\\''s'")
    }

    func testDirectoryChangeUsesDoubleDashAndQuotes() {
        XCTAssertEqual(
            ShellCommand.directoryChange(toAbsolutePath: "/Users/a/my dir"),
            "cd -- '/Users/a/my dir'"
        )
        XCTAssertEqual(ShellCommand.submitted("cd -- /tmp"), "cd -- /tmp\r")
    }

    /// 端到端：把生成的命令真的交给 shell 执行。
    ///
    /// 只断言字符串形状是不够的 —— 转义写错时字符串看着依然"很合理"，
    /// 只有让真正的消费者（shell）解一遍才知道对不对。
    func testDirectoryChangeSurvivesARealShell() throws {
        let names = [
            "workspace",                 // 普通
            "my workspace",              // 空格
            "it's a workspace",          // 单引号
            "工作区-中文",                // 非 ASCII
            "trailing space ",           // 结尾空格
            "$HOME-not-expanded",        // 不该被展开的美元符号
            "quote\"and\\backslash",     // 双引号与反斜杠
        ]

        for name in names {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cogniterm-\(UUID().uuidString)")
                .appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

            // 用 /private 前缀统一（/tmp 是符号链接），避免拿到的 pwd 与传入值字面不同。
            let target = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath()

            let command = ShellCommand.directoryChange(toAbsolutePath: target.path) + " && pwd"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let raw = String(decoding: data, as: UTF8.self)
            // 只剥掉 pwd 输出结尾的那一个换行 —— 不能用 trimmingCharacters，
            // 那会把路径里有意义的首尾空格一起吃掉，正好掩盖转义 bug。
            var output = raw
            if output.hasSuffix("\n") { output.removeLast() }
            if output.hasSuffix("\r") { output.removeLast() }
            XCTAssertEqual(process.terminationStatus, 0, "「\(name)」的命令执行失败：\(raw)")
            XCTAssertEqual(output, target.path, "「\(name)」解析出的目录不对")
        }
    }
}
