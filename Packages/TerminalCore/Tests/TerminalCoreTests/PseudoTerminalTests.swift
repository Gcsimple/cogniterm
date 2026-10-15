import XCTest
@testable import TerminalCore

final class PseudoTerminalTests: XCTestCase {

    func testRunsCommandCapturesOutputAndExitCode() {
        let pty = PseudoTerminal()
        let output = NSMutableData()
        let exited = expectation(description: "子进程退出")

        pty.onOutput = { chunk in
            output.append(chunk)
        }
        pty.onExit = { code in
            XCTAssertEqual(code, 7)
            exited.fulfill()
        }

        XCTAssertNoThrow(try pty.launch(.init(
            executablePath: "/bin/zsh",
            arguments: ["-c", "echo DSH_PTY_OK; exit 7"],
            columns: 120, rows: 40
        )))

        wait(for: [exited], timeout: 5)
        let text = String(data: output as Data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("DSH_PTY_OK"), "应收到 PTY 回显，实际：\(text.debugDescription)")
        XCTAssertFalse(pty.isRunning)
    }

    func testResizeAndProcessGroupTermination() {
        let pty = PseudoTerminal()
        let exited = expectation(description: "sleep 被杀掉")
        pty.onExit = { code in
            // 被 SIGTERM 结束：128+15
            XCTAssertEqual(code, 143)
            exited.fulfill()
        }

        XCTAssertNoThrow(try pty.launch(.init(
            executablePath: "/bin/zsh",
            arguments: ["-c", "sleep 30"]
        )))

        pty.setSize(columns: 160, rows: 48)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pty.terminate()
        }
        wait(for: [exited], timeout: 5)
    }

    func testSendInterruptWritesETX() {
        // 用 cat 验证 Ctrl-C：cat 收到 SIGINT 退出，shell 随后结束。
        let pty = PseudoTerminal()
        let exited = expectation(description: "cat 被 SIGINT 中断后 shell 退出")
        pty.onExit = { _ in exited.fulfill() }

        XCTAssertNoThrow(try pty.launch(.init(
            executablePath: "/bin/zsh",
            arguments: ["-c", "cat; exit 0"]
        )))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            pty.sendInterrupt()
        }
        wait(for: [exited], timeout: 5)
    }
}
