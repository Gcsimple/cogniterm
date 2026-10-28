import XCTest
import AppKit
import SwiftTerm
import TerminalCore
@testable import CogniTerm

/// 记录 SwiftTerm 报出的尺寸变化，用于断言"会话靠 sizeChanged 拿真实行列数"这条机制。
@MainActor
private final class SizeRecorder: NSObject, TerminalViewDelegate {
    private(set) var sizes: [(cols: Int, rows: Int)] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sizes.append((newCols, newRows))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
final class TerminalIntegrationTests: XCTestCase {

    private func makeView(cols: Int = 100, rows: Int = 30) -> CogniTerminalView {
        var options = TerminalOptions(cols: cols, rows: rows)
        options.scrollback = 2_000
        return CogniTerminalView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 520),
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: options
        )
    }

    // MARK: - 尺寸：会话启动 shell 的时机就靠这条机制

    func testZeroSizedViewStartsOnPlaceholderGridThenAdoptsRealGrid() {
        var options = TerminalOptions(cols: 4, rows: 4)
        options.scrollback = 2_000
        let view = CogniTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            options: options
        )

        // 视图还没有尺寸时用 startupOptions（刻意给 4x4）。
        XCTAssertEqual(view.terminalDimensions.cols, 4)
        XCTAssertEqual(view.terminalDimensions.rows, 4)

        let recorder = SizeRecorder()
        view.terminalDelegate = recorder
        view.setFrameSize(NSSize(width: 1280, height: 800))

        // 关键断言：这个占位值不可能等于任何真实面板，
        // 所以首次布局必然回调一次 sizeChanged —— 会话据此拿到真实行列数再起 shell。
        XCTAssertFalse(
            recorder.sizes.isEmpty,
            "布局变化必须回调 sizeChanged，否则会话只能靠猜行列数（老版本硬编码 charWidth/lineHeight 就是这么错的）"
        )
        XCTAssertGreaterThan(view.terminalDimensions.cols, 4, "占位网格必须被真实尺寸替换")
        XCTAssertGreaterThan(view.terminalDimensions.rows, 4)
    }

    func testResizePropagatesEveryDistinctGridToTheDelegate() {
        let view = makeView()
        let recorder = SizeRecorder()
        view.terminalDelegate = recorder

        view.setFrameSize(NSSize(width: 640, height: 400))
        let narrow = view.terminalDimensions
        view.setFrameSize(NSSize(width: 1280, height: 800))
        let wide = view.terminalDimensions

        XCTAssertGreaterThan(wide.cols, narrow.cols)
        XCTAssertGreaterThan(wide.rows, narrow.rows)
        XCTAssertTrue(
            recorder.sizes.contains { $0.cols == wide.cols && $0.rows == wide.rows },
            "最终尺寸必须报给 delegate（→ TIOCSWINSZ），实际：\(recorder.sizes)"
        )
    }

    // MARK: - 端到端：环境 → forkpty → 子进程 → SwiftTerm 缓冲区

    /// 一次串起整条链路，判据落在**子进程真实看到的东西**和**终端缓冲区里的字节**上。
    ///
    /// 只断言我们构造的字典里有/没有某个键是不够的 —— 上一窗口就吃过这个亏：
    /// `sidecar.sb` 文本完全正确、`cmp` 一致、单测全过，实际语义却是禁网。
    func testShellSeesSanitizedEnvironmentAndItsOutputLandsInTheTerminalBuffer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cogniterm-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let base: [String: String] = [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin:/bin",
            "HTTPS_PROXY": "http://127.0.0.1:59999",
            "http_proxy": "http://127.0.0.1:59999",
            "DYLD_INSERT_LIBRARIES": "/tmp/cogniterm-evil.dylib",
        ]

        let profile = TerminalProfile.standard(
            workingDirectory: directory,
            columns: 100,
            rows: 30,
            base: base,
            isExecutable: { _ in true },
            programName: "CogniTerm",
            programVersion: "0.0.0-test"
        )
        XCTAssertEqual(profile.executablePath, "/bin/zsh")
        XCTAssertEqual(profile.arguments, ["-l", "-i"])

        // 交互式 shell 的提示符时机本身不确定，把参数换成 -c 让断言确定；
        // 环境、cwd、PTY、SwiftTerm 解析这一段全是真实的那条路径。
        var config = profile.ptyConfig(workingDirectory: directory, columns: 100, rows: 30)
        config.arguments = ["-c", [
            #"printf 'TERM=%s\n' "$TERM""#,
            #"printf 'COLORTERM=%s\n' "$COLORTERM""#,
            #"printf 'PROGRAM=%s\n' "${TERM_PROGRAM:-absent}""#,
            #"printf 'PROXY=%s\n' "${HTTPS_PROXY:-absent}""#,
            #"printf 'lower_proxy=%s\n' "${http_proxy:-absent}""#,
            #"printf 'DYLD=%s\n' "${DYLD_INSERT_LIBRARIES:-absent}""#,
            #"printf 'PWD=%s\n' "$(pwd -P)""#,
            #"printf 'MARK=%s\n' "COGNITERM_E2E_MARK""#,
        ].joined(separator: "\n")]

        let view = makeView()
        let pty = PseudoTerminal()
        // 与生产路径一致：在 PTY 自己的读取队列上直接喂给终端模型，不跳主线程。
        pty.onOutput = { data in
            view.feed(byteArray: Array(data)[...])
        }
        let exited = expectation(description: "shell 退出")
        pty.onExit = { _ in exited.fulfill() }

        try pty.launch(config)
        wait(for: [exited], timeout: 20)

        let text = String(decoding: view.getBufferAsData(kind: .active, encoding: .utf8), as: UTF8.self)

        XCTAssertTrue(text.contains("TERM=xterm-256color"),
                      "子进程必须看到 xterm-256color，实际缓冲区：\n\(text)")
        XCTAssertTrue(text.contains("COLORTERM=truecolor"), "实际：\n\(text)")
        XCTAssertTrue(text.contains("PROGRAM=CogniTerm"), "实际：\n\(text)")
        XCTAssertTrue(text.contains("PROXY=absent"),
                      "父进程的代理变量漏进子 shell 了（本机每次工具调用都会注入一个临时端口代理）")
        XCTAssertTrue(text.contains("lower_proxy=absent"), "小写代理变量同样要剔")
        XCTAssertTrue(text.contains("DYLD=absent"),
                      "自己给 environment 时 PseudoTerminal 不会替你过滤 DYLD_*")
        XCTAssertTrue(text.contains("MARK=COGNITERM_E2E_MARK"),
                      "PTY 输出没有走通到 SwiftTerm 缓冲区")

        // cwd 断言两端各退一步：macOS 上 /var 是 private/var 的符号链接，
        // 而 `URL.resolvingSymlinksInPath()` 在沙箱里解析不了它（broker 拒
        // readlink，原样返回 /var/...），子 shell 的 `pwd -P` 走 getcwd()
        // 又一定给物理路径 /private/var/...。全等比较会在沙箱里假失败。
        // 改用「唯一目录名后缀」——chdir 真失败时 PWD 是仓库根，不含这个 UUID。
        let uniqueName = directory.lastPathComponent
        let pwdLines = text.split(separator: "\n").filter { $0.hasPrefix("PWD=") }
        XCTAssertEqual(pwdLines.count, 1, "PWD 必须恰好打印一行，实际：\n\(text)")
        let actualDirectory = String(pwdLines.first!.dropFirst("PWD=".count))
        XCTAssertTrue(actualDirectory.hasSuffix("/\(uniqueName)"),
                      "shell 的 cwd 必须落在会话的工作区目录，实际 \(actualDirectory)")
    }

    // MARK: - 控制序列真的被解析（而不是被正则剥掉）

    /// 老实现用正则把 ANSI 全剥掉，颜色/光标/备用屏一起消失。
    /// 这里要求视图**解析**这些序列：颜色进属性、备用屏切换生效。
    func testTerminalParsesControlSequencesInsteadOfStrippingThem() {
        let view = makeView()

        view.feed(text: "\u{1b}[31mRED\u{1b}[0m")
        let normal = String(decoding: view.getBufferAsData(kind: .normal, encoding: .utf8), as: UTF8.self)
        XCTAssertTrue(normal.contains("RED"), "字符本身要在缓冲区里")

        // 进入备用屏 → 写内容 → 正常屏不该看到它。vim/less/htop 全靠这个。
        view.feed(text: "\u{1b}[?1049h")
        view.feed(text: "ALTERNATE_SCREEN_TEXT")
        let active = String(decoding: view.getBufferAsData(kind: .active, encoding: .utf8), as: UTF8.self)
        XCTAssertTrue(active.contains("ALTERNATE_SCREEN_TEXT"), "备用屏内容应出现在 active 缓冲区")

        view.feed(text: "\u{1b}[?1049l")
        let backToNormal = String(decoding: view.getBufferAsData(kind: .active, encoding: .utf8), as: UTF8.self)
        XCTAssertFalse(backToNormal.contains("ALTERNATE_SCREEN_TEXT"),
                       "退出备用屏后不该再看到里面的文字")
        XCTAssertTrue(backToNormal.contains("RED"), "正常屏内容应该原样还在")
    }

    // MARK: - 键盘快捷键（iTerm2 / Terminal.app 事实标准键位）

    /// 键位映射必须与系统终端一致，否则用户换过来每个键都要重新学。
    /// 这是"体验不如 mac 自带 zsh"里最便宜就能补上的一块。
    func testTerminalShortcutMappingMatchesITerm2Keys() {
        XCTAssertEqual(TerminalShortcut.resolve(character: "k"), .clear)
        XCTAssertEqual(TerminalShortcut.resolve(character: "f"), .find)
        XCTAssertEqual(TerminalShortcut.resolve(character: "r"), .restart)
        XCTAssertEqual(TerminalShortcut.resolve(character: "."), .interrupt)
        XCTAssertEqual(TerminalShortcut.resolve(character: "+"), .zoomIn)
        XCTAssertEqual(TerminalShortcut.resolve(character: "="), .zoomIn)
        XCTAssertEqual(TerminalShortcut.resolve(character: "-"), .zoomOut)
        XCTAssertEqual(TerminalShortcut.resolve(character: "0"), .zoomReset)

        // 这三个**绝不能**进来：它们是 AppKit 的复制/粘贴/全选，
        // 拦了就等于终端里没法复制粘贴。
        XCTAssertNil(TerminalShortcut.resolve(character: "c"))
        XCTAssertNil(TerminalShortcut.resolve(character: "v"))
        XCTAssertNil(TerminalShortcut.resolve(character: "a"))
        // 没被占用的键也不能误伤（留给 shell 和将来的功能）。
        XCTAssertNil(TerminalShortcut.resolve(character: "z"))
        XCTAssertNil(TerminalShortcut.resolve(character: "t"))
    }

    /// 焦点状态机：终端成为/退出第一响应者时，必须把焦点状态发布出去。
    ///
    /// 这条状态是菜单项的 disabled 判据 —— 不区分焦点就会在聊天输入框里按
    /// Cmd-K 把终端清屏、Cmd-R 把 shell 重启，而用户根本没在看终端。
    /// 之所以不用 SwiftUI focus 环境值：焦点由 NSView 的 become/resign 发布，
    /// 消费方隔着 `NSViewRepresentable`，SwiftUI focus 系统看不到它。
    func testTerminalFocusTracksFirstResponderChanges() {
        let view = makeView()
        XCTAssertFalse(TerminalFocus.shared.isTerminalFocused, "初始不能是聚焦态")

        XCTAssertTrue(view.becomeFirstResponder(),
                      "TerminalView.acceptsFirstResponder 恒为 true，这里必须接受焦点")
        XCTAssertTrue(TerminalFocus.shared.isTerminalFocused,
                      "成为第一响应者必须发布焦点，否则菜单里的 Cmd-K/Cmd-R 不会启用")

        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(TerminalFocus.shared.isTerminalFocused,
                       "退出第一响应者必须收回焦点，否则失焦后快捷键仍然生效")

        // 要能来回翻转：菜单项在两次切换之间都必须拿到正确状态。
        XCTAssertTrue(view.becomeFirstResponder())
        XCTAssertTrue(TerminalFocus.shared.isTerminalFocused)
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(TerminalFocus.shared.isTerminalFocused)
    }

    /// 焦点守卫必须是**成对**的：只发布不收回时，关掉窗口后还在原位置按快捷键
    /// 会打到已经不存在的终端上（`detach()` 也做了清理，这里钉住视图侧）。
    func testFocusIsRevokedWhenViewResignsWithoutEverBecomingResponder() {
        let view = makeView()
        // 从没 become 过的视图 resign：状态必须保持 false，不能被置真。
        XCTAssertTrue(view.resignFirstResponder())
        XCTAssertFalse(TerminalFocus.shared.isTerminalFocused)
    }

    /// 字号快捷键必须夹在预设档位里：等宽字体在小数号上栅格化很难看，
    /// 所以是离散档位。夹不住会一路缩到看不见 / 涨出面板。
    func testFontSizeShortcutsClampWithinPresets() {
        let session = TerminalSession()

        session.handleShortcut(.zoomOut)
        XCTAssertEqual(session.fontSize, 11)
        session.handleShortcut(.zoomIn)
        XCTAssertEqual(session.fontSize, 12)
        session.handleShortcut(.zoomReset)
        XCTAssertEqual(session.fontSize, 12, "Cmd-0 恢复默认档")

        for _ in 0..<30 { session.handleShortcut(.zoomIn) }
        XCTAssertEqual(session.fontSize, 24, "放大不能越过最大档")
        for _ in 0..<30 { session.handleShortcut(.zoomOut) }
        XCTAssertEqual(session.fontSize, 9, "缩小不能跌破最小档")
    }

    // MARK: - 回看与提示

    /// "往上翻了就回不去"是最刺眼的体验缺陷之一：滚动委托原来是空实现，
    /// 用户只能手动拖滚动条，而且 `tail -f` 时新输出静默滚走、毫无提示。
    func testScrollingAwayFromBottomEntersHistoryModeAndBackResets() {
        let session = TerminalSession()
        XCTAssertFalse(session.isViewingHistory, "初始就在底部")

        session.observeScroll(position: 0.5)
        XCTAssertTrue(session.isViewingHistory, "离开底部必须进入回看态，否则不会浮出回到底部")

        session.scrollToBottom()
        XCTAssertFalse(session.isViewingHistory)
        XCTAssertEqual(session.unseenOutputChunks, 0)
    }

    /// 位置没变时 SwiftTerm 不会回调 `scrolled`，所以 `scrollToBottom` 必须自己
    /// 把状态归位 —— 否则 `isViewingHistory` 会卡在 true。
    func testScrollToBottomResetsStateEvenWhenPositionIsUnchanged() {
        let session = TerminalSession()
        session.observeScroll(position: 0.5)
        XCTAssertTrue(session.isViewingHistory)

        // 没有视图：view?.scroll 是 no-op，但状态必须仍然归位。
        session.scrollToBottom()
        XCTAssertFalse(session.isViewingHistory)
        XCTAssertEqual(session.unseenOutputChunks, 0)
    }

    /// BEL 改成视觉提示：SwiftTerm 默认 `NSSound.beep()`，
    /// 跑构建/测试时连续蜂鸣能把人逼疯（Terminal.app/iTerm2 默认都只做视觉提示）。
    func testBellShowsTransientVisualHintAndClearsItself() {
        let session = TerminalSession()
        XCTAssertFalse(session.bellActive)

        session.observeBell()
        XCTAssertTrue(session.bellActive, "收到 BEL 必须立刻有视觉反馈")

        let cleared = expectation(description: "视觉提示自动收回")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !session.bellActive { cleared.fulfill() }
        }
        wait(for: [cleared], timeout: 4)
    }

    // MARK: - 选区引用（终端 → agent 上下文）

    /// quote store 的生命周期：写入（去空白）→ 计数 → 空白视为无 → 清空。
    /// 单例共享状态，测试自管理（先 clear）。
    func testTerminalQuoteStoreLifecycle() {
        let store = TerminalQuoteStore.shared
        store.clear()
        XCTAssertNil(store.quote)
        XCTAssertFalse(store.hasQuote)

        store.setQuote("  line1\nline2  ")
        XCTAssertEqual(store.quote, "line1\nline2", "首尾空白要剥掉，中间结构保留")
        XCTAssertEqual(store.quoteLineCount, 2)
        XCTAssertTrue(store.hasQuote)

        store.setQuote("   \n  ")
        XCTAssertNil(store.quote, "全空白引用视为无引用")

        store.setQuote("kept")
        store.clear()
        XCTAssertNil(store.quote)
    }

    // MARK: - ANSI 剥离（回喂给 agent 的输出必须干净）

    func testStripANSIRemovesColorCursorAndOSCSequences() {
        XCTAssertEqual(stripANSIEscapeSequences("\u{1b}[31mRED\u{1b}[0m normal"), "RED normal")
        XCTAssertEqual(stripANSIEscapeSequences("abc\u{1b}[2Jdef"), "abcdef")
        XCTAssertEqual(stripANSIEscapeSequences("\u{1b}]0;window title\u{7}body"), "body")
        XCTAssertEqual(stripANSIEscapeSequences("\u{1b}[32m构建成功\u{1b}[0m"), "构建成功")
        XCTAssertEqual(stripANSIEscapeSequences("\u{1b}[1;38;5;208mwarn\u{1b}[0m"), "warn")
        // 普通文本一个字节都不能动：控制符形态的正文（printf '%s'）要原样保留。
        XCTAssertEqual(stripANSIEscapeSequences("printf '%s' x"), "printf '%s' x")
        XCTAssertEqual(stripANSIEscapeSequences("plain text"), "plain text")
    }

    // MARK: - 终端面板高度（拖拽手柄 + 自适应）

    /// 行高必须和 SwiftTerm 同口径：`ceil(ascender - descender + leading)`。
    /// 差 1pt 无所谓，但「18 行」在 300pt 上会差出整整一行——所以这里钉死。
    func testCellHeightMatchesSwiftTermCellMetrics() {
        let twelve = TerminalPanelSizing.cellHeight(fontSize: 12)
        XCTAssertEqual(twelve, 15, "12pt SF Mono：ceil(11.60 + 2.53) = 15")
        XCTAssertEqual(TerminalPanelSizing.cellHeight(fontSize: 9), 11)
        XCTAssertGreaterThan(TerminalPanelSizing.cellHeight(fontSize: 24), twelve)
    }

    /// chrome = 标签栏 26 + 工具条 28 + 两条分隔线 2。改其中一个数必须改这里。
    func testChromeHeightAddsUpToTheRealSubviews() {
        XCTAssertEqual(TerminalPanelSizing.chromeHeight, 56)
        // 18 行 + chrome：12pt 字号下是 56 + 270 = 326。
        XCTAssertEqual(TerminalPanelSizing.heightForMinimumRows(fontSize: 12), 326)
    }

    /// 用户抱怨「太小」的那个窗口实测是 1280×652，detail 区约 624pt 高。
    /// 旧固定值 220pt → (220-56)/15 ≈ 11 行。现在应该给到 18 行下限。
    func testIdealHeightHonoursMinimumRowsOnTypicalWindow() {
        let height = TerminalPanelSizing.idealHeight(available: 624, fontSize: 12)
        XCTAssertEqual(height, 326, "0.42×624=262 比行数下限矮，取下限")
        XCTAssertEqual(TerminalPanelSizing.visibleRows(height: height, fontSize: 12), 18)
        // 让出去的高度之后，对话区还剩多少？必须仍在它自己的下限之上。
        let conversationArea = 624 - height - TerminalPanelSizing.handleHeight
        XCTAssertGreaterThanOrEqual(conversationArea, TerminalPanelSizing.conversationFloor,
                                    "终端高度不得侵吞对话区下限")
    }

    /// 窗口够高时比例接管：900pt 的 detail 区给 0.42 ≈ 22 行。
    func testIdealHeightGrowsWithWindow() {
        let height = TerminalPanelSizing.idealHeight(available: 900, fontSize: 12)
        XCTAssertEqual(height, 378, accuracy: 0.01)
        let rows = TerminalPanelSizing.visibleRows(height: height, fontSize: 12)
        XCTAssertGreaterThan(rows, 20)
        // 单调：窗口更高只会更多，不会更少。
        XCTAssertGreaterThan(height,
                             TerminalPanelSizing.idealHeight(available: 700, fontSize: 12))
    }

    /// 窗口矮到装不下 18 行 + 对话区下限时，**让对话区**：封顶优先于行数下限。
    func testConversationFloorWinsOnShortWindow() {
        let short: CGFloat = 560
        let height = TerminalPanelSizing.idealHeight(available: short, fontSize: 12)
        let budget = Double(short) - Double(TerminalPanelSizing.conversationFloor)
                        - Double(TerminalPanelSizing.handleHeight)
        XCTAssertEqual(height, budget, accuracy: 0.01, "矮窗口里封顶说话")
        XCTAssertLessThan(TerminalPanelSizing.visibleRows(height: height, fontSize: 12), 18)
    }

    /// 放大字号 → 行数下限变高 → 自适应面板跟着长。
    /// 不做这件事的话，字号调到 20pt 反而看得更少（这就是旧固定值的毛病）。
    func testIdealHeightFollowsFontSize() {
        let small = TerminalPanelSizing.idealHeight(available: 900, fontSize: 12)
        let large = TerminalPanelSizing.idealHeight(available: 900, fontSize: 20)
        XCTAssertGreaterThan(large, small, "字大了面板必须跟着长，否则行数反而掉")
        // 1600pt 的大屏才装得下 20pt 字号的 18 行，这里只断言它没被预算压回原值。
        XCTAssertLessThanOrEqual(large, 900 - Double(TerminalPanelSizing.conversationFloor))
    }

    /// 拖拽存值不按当前窗口夹：窗口拖小一次不该让终端永久变矮。
    func testCustomHeightDoesNotRatchetDownWithWindow() {
        let dragged = TerminalPanelSizing.clampedCustomHeight(700)
        XCTAssertEqual(dragged, 700, "存的是意图，不是当前窗口的显示值")
        // 同一份意图在小窗口里被压到预算，回到大窗口又能张开。
        let smallWindow = TerminalPanelSizing.displayHeight(desired: dragged, available: 624, fontSize: 12)
        let largeWindow = TerminalPanelSizing.displayHeight(desired: dragged, available: 1100, fontSize: 12)
        XCTAssertEqual(smallWindow, 624 - Double(TerminalPanelSizing.conversationFloor) - 4, accuracy: 0.01)
        XCTAssertEqual(largeWindow, 700, "回到大窗口恢复用户设定的高度")
    }

    /// 拖到下界的极端情况：不许低于「chrome + 一行」，否则面板只剩一条缝。
    func testCustomHeightFloorKeepsOneRowVisible() {
        let bottom = TerminalPanelSizing.clampedCustomHeight(-500)
        XCTAssertEqual(bottom, TerminalPanelSizing.floorHeight, accuracy: 0.01)
        XCTAssertGreaterThan(TerminalPanelSizing.visibleRows(height: bottom, fontSize: 12), 0)
        XCTAssertEqual(TerminalPanelSizing.clampedCustomHeight(99_999),
                       TerminalPanelSizing.absoluteMax, "上限防手滑")
    }

    // MARK: - 「在终端运行」（审批卡出口）

    /// pty 未就绪（视图没 attach / shell 没起）时必须**同步**给出空结果并记诊断，
    /// 不能挂起——审批卡那边正拿着这个回调决定是否回喂。
    func testRunCommandCapturedWithoutPtyReportsImmediately() {
        let session = TerminalSession()

        let captured = expectation(description: "无 pty 也应回调")
        session.runCommandCaptured("echo hi") { text in
            XCTAssertEqual(text, "", "没有终端可跑，回喂空输出")
            captured.fulfill()
        }
        wait(for: [captured], timeout: 2)
        XCTAssertEqual(session.runState, .idle, "pty 未就绪不应进入 running")
        XCTAssertFalse(session.diagnostics.isEmpty, "要留下诊断说明为什么没跑")
    }

    /// idle 态下 skip/flush 必须是 no-op：不能凭空回喂，也不能改状态。
    func testSkipAndFlushAreNoOpsWhenIdle() {
        let session = TerminalSession()
        session.skipRunCapture()
        XCTAssertEqual(session.runState, .idle)

        let noFlush = expectation(description: "idle 时不得回喂")
        noFlush.isInverted = true
        session.flushRunCapture { _ in
            XCTFail("idle 状态不应触发回喂")
        }
        wait(for: [noFlush], timeout: 0.5)
        XCTAssertEqual(session.runState, .idle)
    }

    /// 端到端：真起 shell → 注入命令 → PTY 输出进缓冲区 → 静默收敛 → 剥净 ANSI
    /// 的回调文本包含命令输出。这条链是「审批卡在终端运行」的脊梁，
    /// 判据落在**真实捕获到的文本**上（不是看按钮状态）。
    func testRunCommandCapturedFeedsRealShellOutputBack() async throws {
        let session = TerminalSession()
        let view = makeView()
        // 生产路径：MainSplitView.onAppear 先给会话工作区根目录，视图就绪时才
        // attach（TerminalCanvas.Coordinator 转发的就是 sizeChanged 这条路）。
        // 少了 start(root:) 的话 observeSize 的 `let root = workspaceRoot` 直接
        // 返回，shell 永远不启动——这正是这个测试第一版挂掉的原因。
        session.start(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        view.terminalDelegate = SessionWiringDelegate(session: session)
        session.attach(view)
        view.setFrameSize(NSSize(width: 800, height: 400))

        // 等 shell 就绪（launch 由 sizeChanged 触发；异步）。
        for _ in 0..<50 {
            if session.status.isRunning { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(session.status.isRunning, "shell 应已启动：\(session.statusText)")

        let text = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            session.runCommandCaptured("echo CANIMARK_OUTPUT") { captured in
                continuation.resume(returning: captured)
            }
        }
        XCTAssertTrue(text.contains("CANIMARK_OUTPUT"),
                      "回喂文本必须包含命令真实输出，实际：\n\(text)")
        XCTAssertEqual(session.runState, .captured(lines: text.split(separator: "\n").count),
                       "收敛后状态应为 captured")

        // 交互 shell 不会自己退：注入 exit 让测试进程干净收尾。
        session.runCommandCaptured("exit") { _ in }
        try? await Task.sleep(nanoseconds: 500_000_000)
    }

    /// 「发送当前屏幕」：取活跃缓冲区末尾 N 行，剥掉右侧列宽填充、掐掉首尾空行。
    ///
    /// 判据落在 quote store 的**实际文本**上——getBufferAsData 会把每行补齐到
    /// 整列宽（translateBufferLineToString 按列宽输出），不剥的话引用里一半是
    /// 尾随空格；buffer.lines 还含回看历史，不掐尾部的话半小时前的输出也会进来。
    func testSendScreenToAgentQuotesVisibleTailWithoutPadding() {
        let store = TerminalQuoteStore.shared
        store.clear()
        XCTAssertNil(store.quote)

        let session = TerminalSession()
        let view = makeView()
        // 不起 shell（没有 start(root:)）：读缓冲区不需要 PTY。
        session.attach(view)

        view.feed(text: "first line\r\nsecond line")
        view.feed(text: "\r\n\r\n  indented  ")

        session.sendScreenToAgent(lineCount: 50)

        XCTAssertEqual(store.quote, "first line\nsecond line\n\n  indented",
                       "尾随填充空白必须剥掉（前导空格是缩进，要保留），首尾空行要掐掉")
        XCTAssertEqual(store.quoteLineCount, 4)
        store.clear()
    }

    /// 行数上限：buffer.lines 含回看历史，只能取末尾 N 行。
    ///
    /// 断言行为契约而不是精确行号：30 行的视图灌 60 行后 buffer 的确切行数受
    /// 滚动时机影响（末尾换行会把一个空行也滚进来），但契约是硬的——
    /// **必须带上最新输出、必须排除回看历史里的旧输出、行数不得超过上限**。
    func testSendScreenToAgentCapsAtRequestedTail() {
        let store = TerminalQuoteStore.shared
        store.clear()

        let session = TerminalSession()
        let view = makeView()
        session.attach(view)

        // ⚠️ 必须用 \r\n：裸 \n 在终端语义里只换行**不回列**（LF 保持光标列），
        // 真实 shell 发的也是 \r\n——用裸 \n 的话每行都会带着上一行的长度偏移。
        view.feed(text: (1...60).map { "row\($0)" }.joined(separator: "\r\n"))
        session.sendScreenToAgent(lineCount: 10)

        let quote = try? XCTUnwrap(store.quote)
        let lines = quote?.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        XCTAssertLessThanOrEqual(lines.count, 10, "引用行数不得超过上限（末尾空行会被剥掉，所以只少不多）")
        XCTAssertGreaterThanOrEqual(lines.count, 9, "上限 10 行时至少应带上 9 行非空内容")
        XCTAssertEqual(lines.last.map(String.init), "row60", "必须带到最新一行")
        XCTAssertFalse(lines.contains("row30"), "回看历史里的旧输出（row30）不能混进引用")
        store.clear()
    }

    /// 没有视图时不能凭空引用，必须留诊断（与其他失败路径同规矩：不静默）。
    func testSendScreenToAgentWithoutViewNotesDiagnostic() {
        let store = TerminalQuoteStore.shared
        store.clear()

        let session = TerminalSession()
        session.sendScreenToAgent()

        XCTAssertNil(store.quote, "没有终端视图就不该有引用内容")
        XCTAssertFalse(session.diagnostics.isEmpty, "读取失败要留下诊断说明")
    }

    /// 尺寸变化转发给会话（「在终端运行」e2e 测试的接线委托）。
    @MainActor
    private final class SessionWiringDelegate: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.observeSize(columns: newCols, rows: newRows)
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
