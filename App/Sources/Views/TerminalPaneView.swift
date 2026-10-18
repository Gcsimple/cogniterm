import SwiftUI
import AppKit
import TerminalCore
import SwiftTerm

// 字号档位（pt）。用离散档位而不是连续缩放：等宽字体在小数号上栅格化很难看。
private let terminalFontSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24]
private let defaultTerminalFontSizeIndex = 3
private let terminalScrollbackLines = 10_000

// MARK: - 键盘快捷键

/// 终端面板的**应用级**键盘动作。
///
/// 边界划得很死：只有"终端这个面板自己的功能"才进来（清屏/查找/重启/字号…），
/// shell 需要的键**一个都不碰**，原样透传给 PTY —— 方向键、Tab、Ctrl-R、Ctrl-C、
/// Ctrl-A、Ctrl-E 全部走 `send(source:data:)` 那条路。
///
/// 键位照 iTerm2 / Terminal.app 的事实标准取（Cmd-K 清屏、Cmd-F 查找、Cmd-R 重启、
/// Cmd-. 中断、Cmd-±/Cmd-0 字号）。macOS 用户换终端不用重新学，这是"体验不如
/// 系统自带 zsh"里最便宜就能补上的一块。
enum TerminalShortcut: Equatable {
    /// Cmd-K：清屏 + 清回看缓冲
    case clear
    /// Cmd-F：在回看缓冲里查找
    case find
    /// Cmd-R：重启 shell
    case restart
    /// Cmd-.：发送 Ctrl-C（Terminal.app 的中断键）
    case interrupt
    /// Cmd-+ / Cmd-=
    case zoomIn
    /// Cmd-- / Cmd-_
    case zoomOut
    /// Cmd-0：恢复默认字号
    case zoomReset
}

extension TerminalShortcut {
    /// 从按键字符解析动作。**纯函数**（不碰 AppKit 状态），所以能直接单测。
    ///
    /// 调用方负责保证：已经带 Command、且不含 Ctrl/Option。带 Ctrl/Option 的
    /// 组合可能是 shell 自己的键（Ctrl- 系列一律不在这里出现），不能拦。
    static func resolve(character: Character) -> TerminalShortcut? {
        switch character {
        case "k": return .clear
        case "f": return .find
        case "r": return .restart
        case ".": return .interrupt
        case "+", "=": return .zoomIn
        case "-", "_": return .zoomOut
        case "0": return .zoomReset
        default: return nil
        }
    }
}

/// 终端是否持有键盘焦点。给菜单栏的「终端」菜单用来启停快捷键。
///
/// 为什么需要它：终端的快捷键是**宿主菜单项**（⌘K / ⌘F / ⌘R …），而菜单项在
/// 整个 App 里都按得到。不区分焦点就会在聊天输入框里按 ⌘K 把终端清屏。
///
/// 单例而不是 SwiftUI focus 环境值：焦点由 `CogniTerminalView`（NSView）在
/// `become/resignFirstResponder` 里发布，而消费方是 Scene 级的 `Commands` ——
/// 中间隔着一层 `NSViewRepresentable`，SwiftUI 的 focus 系统看不到它。
@MainActor
final class TerminalFocus: ObservableObject {
    static let shared = TerminalFocus()
    private init() {}

    @Published private(set) var isTerminalFocused = false

    /// 焦点进出。方法而不是公开 setter：赋值点只有 `become/resignFirstResponder`
    /// 和 `detach()`，收在一个方法里便于审查（公开 setter 会被到处乱写）。
    func setFocused(_ value: Bool) {
        isTerminalFocused = value
    }
}

/// 「终端选区 → agent 输入框」的搬运工。
///
/// 为什么单独一个 store：产线是「TerminalPanel 的按钮 / 菜单项写进去，
/// ComposerView 读出来」，两边在视图树的不同分支（一个在 VSplitView 下半、
/// 一个在上半），用 SwiftUI 环境值或逐层传参都会把 MainSplitView 撑爆。
/// 单例 + @Published 是最短路径，和 `TerminalFocus` 同一个套路。
///
/// quote 的生命周期：写入 → ComposerView 顶部显示 chip → 发送时拼进 prompt 并清空，
/// 或用户点 chip 上的 × 丢弃。**不落盘**——它是「这一次想问什么」的临时状态，
/// 跨会话保留一段终端输出没有意义。
@MainActor
final class TerminalQuoteStore: ObservableObject {
    static let shared = TerminalQuoteStore()
    private init() {}

    @Published private(set) var quote: String?

    var hasQuote: Bool {
        guard let quote else { return false }
        return !quote.isEmpty
    }

    /// 引用行数（chip 上显示「N 行」）。
    var quoteLineCount: Int {
        guard let quote else { return 0 }
        return quote.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    func setQuote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        quote = trimmed.isEmpty ? nil : trimmed
    }

    func clear() {
        quote = nil
    }
}

/// 剥掉 ANSI/VT 转义序列，留下纯文本。
///
/// 回喂给 agent 的终端输出必须是干净的：控制符混进 prompt 文本会干扰
/// LLM 的分词，而且 JSONL 里存一堆 `\u{1b}[31m` 也没法看。
/// 只处理 CSI/OSC 两大类（SGR 颜色、光标移动、清屏、标题），
/// 其余原样保留——宁可少剥，也不要把正常文本吃掉。
func stripANSIEscapeSequences(_ text: String) -> String {
    // CSI：ESC [ 参数字节 中间字节 终止字节
    // OSC：ESC ] ... BEL 或 ESC \
    // 单字符转义（如 ESC ( B 的字符集切换）一并处理。
    let pattern = "\u{1b}\\[[0-9;?]*[ -/]*[@-~]|\u{1b}\\][^\u{7}\u{1b}]*(?:\u{7}|\u{1b}\\\\)|\u{1b}[@-Z\\\\-_]"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
}

// MARK: - PTY → 终端视图的输出泵

/// PTY 读取线程与终端视图之间唯一的桥。
///
/// **为什么不让 `onOutput` 跳主线程再喂**：`yes`、`find /`、`cat 大文件` 这类输出会在
/// 主线程排起一条永远追不上的队列，整个 UI 一起卡住。SwiftTerm 的
/// `feed(byteArray:)` 明确标了 `nonisolated`（上游自己的 `LocalProcessTerminalView`
/// 也是在读写线程上直接喂），所以这里在 PTY 队列上直接喂。
///
/// 代际（generation）用来丢弃已被替换掉的 shell 的残余输出：重启时旧 shell 可能
/// 还会吐出几百毫秒的数据，混进新会话里非常难查。
private final class TerminalOutputPump: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private weak var view: TerminalView?

    /// 作废当前代际并返回新的。任何"先作废再启动"的地方都调它。
    @discardableResult
    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        return generation
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func bind(view: TerminalView?) {
        lock.lock()
        defer { lock.unlock() }
        self.view = view
    }

    /// 记录"用户是否正在翻回看历史"。翻历史期间的新输出要计数提示，
    /// 否则用户根本不知道身后又刷了一屏（`tail -f` 场景最常见）。
    func setViewingHistory(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        viewingHistory = value
    }

    /// 在 PTY 队列上设置"翻历史期间来了新输出"的回调。
    /// 回调在 PTY 线程被调用，实现方自己负责跳主线程，所以这里不标 @MainActor。
    func bindUnseenOutput(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        onUnseenWhileAway = handler
    }

    func feed(_ data: Data, generation expected: Int) {
        lock.lock()
        guard expected == generation, let view else {
            lock.unlock()
            return
        }
        let notify = !viewingHistory
        // 捕获期（「在终端运行」）同时记录原文与最后输出时刻，供收敛判定。
        let shouldRecord = recording
        if shouldRecord {
            lastOutputDate = Date()
            recordedText += String(decoding: data, as: UTF8.self)
        }
        lock.unlock()
        if notify { onUnseenWhileAway?() }
        // 在锁外喂：feed 自己会去拿终端锁，持着本锁调用会把两条锁序叠在一起。
        view.feed(byteArray: Array(data)[...])
    }

    // MARK: 捕获（审批卡「在终端运行」用）

    func beginRecording() {
        lock.lock()
        defer { lock.unlock() }
        recording = true
        recordedText = ""
        lastOutputDate = nil
    }

    /// 结束捕获。第二个返回值为「期间是否收到过任何输出」——
    /// 从未输出过说明命令根本没跑起来（pty 写失败/命令不存在），回喂时值得区别措辞。
    @discardableResult
    func endRecording() -> (text: String, everOutput: Bool) {
        lock.lock()
        defer { lock.unlock() }
        recording = false
        let result = (recordedText, lastOutputDate != nil)
        recordedText = ""
        lastOutputDate = nil
        return result
    }

    /// 距最后一次输出过了多少秒；捕获期内从未输出过则 nil。
    func secondsSinceLastOutput() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard let last = lastOutputDate else { return nil }
        return Date().timeIntervalSince(last)
    }

    private var viewingHistory = true
    private var onUnseenWhileAway: (@Sendable () -> Void)?
    private var recording = false
    private var recordedText = ""
    private var lastOutputDate: Date?
}

// MARK: - 会话

/// 本地 shell 会话：`TerminalCore.PseudoTerminal` 管进程，SwiftTerm 管终端语义。
///
/// 分工是刻意的 —— PTY 那层（forkpty / TIOCSWINSZ / 进程组回收）已经有测试覆盖，
/// 而复用 SwiftTerm 换来的是真正的终端语义：VT 解析、备用屏、鼠标上报、
/// 滚动回看、选区复制、IME。老版本自己用正则剥 ANSI、按键攒在 TextField 里
/// 回车才整行发，vim / less / htop / Ctrl-R / Tab 补全全部不可用。
@MainActor
final class TerminalSession: ObservableObject {

    /// 进程内唯一实例。
    ///
    /// 之所以要做成单例：快捷键是 **Scene 级 `Commands` 菜单项**，而菜单在
    /// `App` 上、拿不到 `MainSplitView` 里的 `@StateObject`。`SidecarService`
    /// 已经是同样的形态，跟着来。
    static let shared = TerminalSession()

    enum Status: Equatable {
        case idle
        case running(shell: String)
        case exited(code: Int32)
        case failed(message: String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// 「在终端运行」出口的运行时状态。
    enum TerminalRunState: Equatable {
        case idle
        /// 命令已注入 PTY，等待输出收敛。
        case running(command: String)
        /// 已收敛并回喂（lines 是回喂文本的行数，浮层显示用）。
        case captured(lines: Int)
    }

    @Published private(set) var status: Status = .idle
    /// 终端自己设的标题（OSC 0/2）。zsh 的 PROMPT 里常带。
    @Published private(set) var terminalTitle: String = ""
    /// shell 通过 OSC 7 报告的工作目录。多数默认配置不会发，所以可能是 nil。
    @Published private(set) var shellDirectory: String?
    /// 「在终端运行」的运行时状态。审批卡出口见 `runCommandCaptured`。
    @Published private(set) var runState: TerminalRunState = .idle
    @Published private(set) var fontSize: CGFloat = terminalFontSizes[defaultTerminalFontSizeIndex]
    /// 工作区切走了，但终端还停在旧目录。非 nil 时工具条上的同步按钮会高亮。
    @Published private(set) var pendingDirectorySync: String?
    /// 用户已经往上翻、不在底部了。true 时右下角浮出"回到底部"。
    @Published private(set) var isViewingHistory = false
    /// 翻看历史期间新到的输出块数（按 chunk 计，不是精确行数）。
    /// 归零时机：回到底部。`tail -f` / 长构建时靠它知道"身后又刷了一屏"。
    @Published private(set) var unseenOutputChunks = 0
    /// 收到一次 BEL（`\a`）的视觉提示。
    ///
    /// SwiftTerm 的默认实现是 `NSSound.beep()` —— 跑构建/测试连续 BEL 能把人逼疯，
    /// 而且 Terminal.app/iTerm2 都默认只做视觉提示。这里改成闪一下标题图标。
    @Published private(set) var bellActive = false
    /// 终端自身的诊断（OSC 52 异常之类）。有界，只在工具条提示里给人看。
    @Published private(set) var diagnostics: [String] = []

    /// 当前工作区根目录（也用作 shell 的起始 cwd）。
    private(set) var workspaceRoot: URL?

    private nonisolated let pump = TerminalOutputPump()
    private weak var view: TerminalView?
    private var pty: PseudoTerminal?
    private var fontSizeIndex = defaultTerminalFontSizeIndex
    private var launchAttempted = false
    private var launchFallback: DispatchWorkItem?
    private var appliedDarkAppearance: Bool?
    private var bellResetTask: Task<Void, Never>?
    private var convergenceTask: Task<Void, Never>?

    // MARK: 生命周期

    /// 执行平面就绪度（TerminalMCPServer 的 TerminalCommandExecutor 协议）：
    /// PTY 已启动（会话 start 过、视图 attach 触发了 launch）。
    var isTerminalReady: Bool { pty != nil }

    /// 正在捕获某条命令的输出（runState == .running）。MCP 队列据此串行化：
    /// 上一条没收敛前不注入下一条，用户自己的命令也优先。
    var isCapturingCommand: Bool {
        if case .running = runState { return true }
        return false
    }

    func start(root: URL) {
        guard workspaceRoot == nil else { return }
        workspaceRoot = root.standardizedFileURL
        if view != nil { scheduleLaunch() }
    }

    /// 终端视图就绪（`makeNSView`）。视图可能晚于 `start` 出现，也可能早于它。
    func attach(_ view: TerminalView) {
        self.view = view
        pump.bind(view: view)
        pump.bindUnseenOutput { [weak self] in
            Task { @MainActor in
                guard let self, self.isViewingHistory else { return }
                self.unseenOutputChunks += 1
            }
        }
        applyFont(to: view)
        applyNativeColors(to: view)
        scheduleLaunch()
    }

    func detach() {
        pump.bind(view: nil)
        pump.bindUnseenOutput(nil)
        bellResetTask?.cancel()
        bellResetTask = nil
        // 捕获中的命令没有视图可看，收敛也没有意义——直接收摊。
        convergenceTask?.cancel()
        convergenceTask = nil
        runState = .idle
        // 视图要没了，焦点状态必须跟着清：否则菜单里的 ⌘K/⌘R 会一直对着一个
        // 已经不在界面上的终端生效（典型触发：关掉窗口后还在原窗口位置按快捷键）。
        TerminalFocus.shared.setFocused(false)
        view = nil
    }

    /// 工作区切换：**不杀 shell**。
    ///
    /// 旧实现直接 `kill` 再重开，正在跑的构建/ssh 会一起没掉。这里只记住新目录，
    /// 由用户点工具条上的"同步目录"按钮才注入 `cd`。
    ///
    /// 之所以不自动注入：注入 `cd` 必须确认前台没有作业（否则文本会打进 vim/ssh）。
    /// 试过用 `tcgetpgrp(master)` 判前台进程组 —— 对 bash 精确（`sleep 2` 立刻让
    /// 前台组变成子进程组、结束再变回来），但对 zsh **要 1.0~1.6 秒才反映**，
    /// 而且同一脚本不同轮次结果不一致；指望它当门控会在"作业刚起来的窗口期"漏判，
    /// 正好是最危险的那一段。宁可少一个自动行为，也不要往用户的前台程序里打字。
    func workspaceChanged(to url: URL) {
        let standardized = url.standardizedFileURL
        guard workspaceRoot?.path != standardized.path else { return }
        workspaceRoot = standardized
        pendingDirectorySync = pty == nil ? nil : standardized.path
    }

    func restart() {
        stop()
        launchAttempted = false
        pendingDirectorySync = nil
        let size = view?.terminalDimensions
        if let root = workspaceRoot {
            launch(root: root, columns: size?.cols ?? 80, rows: size?.rows ?? 25)
        }
    }

    // MARK: 尺寸

    /// SwiftTerm 报出新行列数。**这是启动 shell 的时机来源**：视图初次布局时
    /// `TerminalView.setFrameSize` → `processSizeChange` → 这里，拿到的就是真实尺寸。
    func observeSize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        if let pty {
            pty.setSize(columns: columns, rows: rows)
            return
        }
        guard !launchAttempted, let root = workspaceRoot else { return }
        launchFallback?.cancel()
        launchFallback = nil
        launch(root: root, columns: columns, rows: rows)
    }

    // MARK: 回看与提示

    /// SwiftTerm 报出滚动位置（0 = 顶，1 = 底）。
    ///
    /// 这条委托原来是个空实现 —— 于是"往上翻了就再也回不去"只能靠手动拖滚动条，
    /// 而且 `tail -f` 场景下用户在历史里时新输出静默滚走，没有任何提示。
    func observeScroll(position: Double) {
        let away = position < 0.999
        guard away != isViewingHistory else { return }
        isViewingHistory = away
        if !away {
            unseenOutputChunks = 0
        }
        pump.setViewingHistory(away)
    }

    /// 回到底部。`scroll(toPosition:)` 是 SwiftTerm 的公开 API，
    /// 与拖动滚动条/滚轮走同一条路径（也会回调 `scrolled`）。
    ///
    /// 状态先归位再滚：视图还没就绪时（或位置本来就在底部、SwiftTerm 不会回调
    /// `scrolled`）也不能把 `isViewingHistory` 卡在 true。
    func scrollToBottom() {
        isViewingHistory = false
        unseenOutputChunks = 0
        pump.setViewingHistory(false)
        view?.scroll(toPosition: 1.0)
    }

    /// BEL（`\a`）：视觉提示，1.5 秒后自动收回。
    func observeBell() {
        bellResetTask?.cancel()
        bellActive = true
        bellResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            bellActive = false
        }
    }

    /// 记一条终端自身诊断。有界（只留最近 20 条），不落盘：
    /// 这类信息是"刚才那次 OSC 52 为什么没成功"级别的，看一眼就够了。
    func noteDiagnostic(_ line: String) {
        diagnostics.append(line)
        if diagnostics.count > 20 { diagnostics.removeFirst(diagnostics.count - 20) }
    }

    // MARK: 输入 / 控制

    func send(_ data: ArraySlice<UInt8>) {
        guard !data.isEmpty else { return }
        pty?.write(Data(data))
    }

    /// 执行一个应用级快捷键。只处理 `TerminalShortcut` 列出的动作，
    /// 其余按键早在 `performKeyEquivalent` 里就透传给 shell 了。
    func handleShortcut(_ shortcut: TerminalShortcut) {
        switch shortcut {
        case .clear: clearScreen()
        case .find: showFind()
        case .restart: restart()
        case .interrupt: interrupt()
        case .zoomIn: zoomIn()
        case .zoomOut: zoomOut()
        case .zoomReset: setFontSizeIndex(defaultTerminalFontSizeIndex)
        }
    }

    func interrupt() {
        pty?.sendInterrupt()
    }

    // MARK: 选区引用（终端 → agent 上下文）

    /// 当前选区的文本；无选区返回 nil。
    ///
    /// `getSelection()` 是 SwiftTerm 的公开 API（`Apple/AppleTerminalView.swift:4813`），
    /// 内部会判 `selection.active`——没有活跃选区时返回 nil，不用自己查。
    func captureSelection() -> String? {
        guard let text = view?.getSelection(), !text.isEmpty else { return nil }
        return text
    }

    var hasSelection: Bool {
        view?.selectionActive ?? false
    }

    /// 「询问 Agent」入口（工具栏按钮与菜单 ⌘I 共用）：
    /// 选区 → quote store → ComposerView 顶部出现引用 chip。
    func askAgentWithSelection() {
        if let selection = captureSelection() {
            TerminalQuoteStore.shared.setQuote(selection)
        } else {
            noteDiagnostic("[terminal] 没有选区：先在终端里拖选一段文本，再按 ⌘I")
        }
    }

    /// 「发送当前屏幕」入口（工具栏按钮与菜单 ⌘⇧I 共用）：
    /// 活跃缓冲区末尾 N 行 → quote store → ComposerView 顶部出现引用 chip。
    ///
    /// 与 ⌘I 的分工：⌘I 发**手选**的精确选区；这个发「眼睛正看着的这一屏」——
    /// 刚跑完的构建输出、tail -f 的最新几行，懒得拖选时用。两条路都进同一个
    /// quote store，ComposerView 的 chip 与发送时拼装逻辑完全复用。
    ///
    /// 实现要点：`getBufferAsData(.active)` 遍历的是 `buffer.lines`——**含回看
    /// 历史**（scrollback 2000 行起步），不能整个塞进引用；且每行会被补齐到整列
    /// 宽（右侧填充空格），必须剥掉再掐首尾空行，否则引用里一半是空白。
    func sendScreenToAgent(lineCount: Int = 50) {
        guard let view else {
            noteDiagnostic("[terminal] 终端视图未就绪，无法读取屏幕内容")
            return
        }
        guard let data = try? view.getBufferAsData(kind: .active, encoding: .utf8) else {
            noteDiagnostic("[terminal] 读取终端缓冲区失败")
            return
        }
        let raw = String(decoding: data, as: UTF8.self)
        // 逐行剥掉右侧填充空白（translateBufferLineToString 按列宽补齐）。
        let trimmedLines = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var end = line.endIndex
                while end > line.startIndex, line[line.index(before: end)] == " " {
                    end = line.index(before: end)
                }
                return line[..<end]
            }
        // 只取末尾 N 行（buffer.lines 含回看历史，全取会带上几分钟前的输出）。
        var tail = Array(trimmedLines.suffix(lineCount))
        while let first = tail.first, first.isEmpty { tail.removeFirst() }
        while let last = tail.last, last.isEmpty { tail.removeLast() }
        guard !tail.isEmpty else {
            noteDiagnostic("[terminal] 当前屏幕没有可引用的内容")
            return
        }
        TerminalQuoteStore.shared.setQuote(tail.joined(separator: "\n"))
    }

    // MARK: 在终端运行（审批卡出口）

    /// 把 agent 申请的命令注入终端执行，并把捕获到的输出回喂给它。
    ///
    /// 为什么是 **reject + 自己跑**而不是 allow：allow 的话 dsh 会在它自己那边
    /// 执行一遍，命令等于跑两次（副作用双倍，`rm -rf` 类命令尤其危险）。
    /// reject 让 dsh 不执行；输出由我们的 PTY 捕获后作为新的 prompt 回喂
    /// agent —— agent 的命令于是在用户的终端里真实可见、可干预，
    /// 输出也回到它的上下文里。这正是「两个执行平面缝合」的关键一招。
    ///
    /// 收敛判定：没有 OSC 133（shell 集成未接）时用「静默 3 秒」启发式，
    /// 2 秒 tick 检查；5 分钟硬超时兜住交互式命令（vim/ssh 永远不静默）。
    /// 等不及可以 `flushRunCapture`（立即回喂已有输出）或 `skipRunCapture`（丢弃）。
    ///
    /// - Parameter command: 审批卡给出的命令文本（已经 ToolCallTracker 补给）。
    /// - Parameter onCapture: 主线程回调，参数是剥净 ANSI、截断过的输出文本。
    func runCommandCaptured(
        _ command: String,
        onCapture: @escaping @MainActor (String) -> Void
    ) {
        guard let pty else {
            noteDiagnostic("[terminal] 终端未就绪，无法在终端运行命令")
            onCapture("")
            return
        }
        runState = .running(command: command)
        pump.beginRecording()
        // 与 syncWorkingDirectory 同一条注入路径：包成 submitted 命令
        ///（带换行）写给 PTY，shell 照常执行——用户能看到、能 Ctrl-C。
        let invocation = ShellCommand.submitted(command)
        pty.write(Data(invocation.utf8))

        convergenceTask?.cancel()
        convergenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let hardDeadline = Date().addingTimeInterval(300)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let idle = self.pump.secondsSinceLastOutput(), idle >= 3 { break }
                if Date() >= hardDeadline { break }
            }
            // 被 flush/skip 抢跑时这里直接让位，不重复 endRecording。
            guard !Task.isCancelled, case .running = self.runState else { return }
            let text = self.finalizeCapture()
            onCapture(text)
        }
    }

    /// 「立即回喂」：不等静默，把当前已捕获的输出发出去（长构建中途想看中间态时用）。
    func flushRunCapture(onCapture: @escaping @MainActor (String) -> Void) {
        convergenceTask?.cancel()
        convergenceTask = nil
        guard case .running = runState else { return }
        let text = finalizeCapture()
        onCapture(text)
    }

    /// 「跳过回喂」：丢弃已捕获的输出，状态归位（用户想自己看、不劳驾 agent）。
    func skipRunCapture() {
        convergenceTask?.cancel()
        convergenceTask = nil
        guard case .running = runState else { return }
        pump.endRecording()
        runState = .idle
    }

    /// 回喂确认浮层 3 秒后收起。
    func dismissCaptured() {
        if case .captured = runState { runState = .idle }
    }

    /// 结束捕获 → 剥 ANSI → 截断 → 更新状态，返回回喂文本。
    private func finalizeCapture() -> String {
        let (raw, everOutput) = pump.endRecording()
        var text = stripANSIEscapeSequences(raw)
        if !everOutput, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = "（终端没有产生任何输出：命令可能不存在、pty 写入失败或立即退出）"
        }
        let truncated: String
        if text.count > 4000 {
            truncated = String(text.prefix(4000)) + "\n…（输出过长，已截断到前 4000 字符）"
        } else {
            truncated = text
        }
        runState = .captured(lines: truncated.split(separator: "\n", omittingEmptySubsequences: false).count)
        return truncated
    }

    /// 清屏 + 清回看缓冲。直接喂给终端模型（等价于 xterm 的 Cmd-K），不打扰 shell。
    func clearScreen() {
        view?.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H")
    }

    // 上游签名是 `copy(_ sender: Any)` / `paste(_ sender: Any)`（非可选），
    // 所以只能塞个 sender 进去；传视图自己是这些 AppKit 动作最省事的惯用写法。
    func copySelection() {
        guard let view else { return }
        view.copy(view)
    }

    func paste() {
        guard let view else { return }
        view.paste(view)
    }

    func selectAll() { view?.selectAll(nil) }

    func showFind() {
        guard let view else { return }
        // `performFindPanelAction` 只认 NSMenuItem 的 tag，这里造一个只带 tag 的。
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        view.performTextFinderAction(item)
    }

    func zoomIn() { setFontSizeIndex(fontSizeIndex + 1) }
    func zoomOut() { setFontSizeIndex(fontSizeIndex - 1) }

    /// 把终端的 cwd 切到工作区根目录。**只在用户点按钮时调用**（见 `workspaceChanged`）。
    func syncWorkingDirectory() {
        guard let root = workspaceRoot, pty != nil else { return }
        let command = ShellCommand.submitted(ShellCommand.directoryChange(toAbsolutePath: root.path))
        pty?.write(Data(command.utf8))
        pendingDirectorySync = nil
    }

    // MARK: 展示

    var statusText: String {
        switch status {
        case .idle: return "未启动"
        case .running(let shell): return (shell as NSString).lastPathComponent
        case .exited(let code): return "已退出（\(code)）"
        case .failed(let message): return "启动失败：\(message)"
        }
    }

    /// 优先显示 shell 自报的目录（OSC 7），没有就显示工作区根。
    var directoryText: String? {
        abbreviatingHome(shellDirectory ?? workspaceRoot?.path)
    }

    func syncHint() -> String? {
        guard let pending = pendingDirectorySync else { return nil }
        return "工作区已切到 \(abbreviatingHome(pending) ?? pending)，点击让终端跟进"
    }

    // MARK: 视图同步

    func applyFont(to view: TerminalView) {
        let wanted = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        guard view.font.pointSize != wanted.pointSize else { return }
        view.font = wanted
    }

    /// 跟随系统浅/深外观。`configureNativeColors()` 读的是动态 NSColor，
    /// 外观切换后必须重新解析一次，否则终端会停在旧配色。
    func applyNativeColors(to view: TerminalView) {
        let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard appliedDarkAppearance != dark else { return }
        appliedDarkAppearance = dark
        view.configureNativeColors()
    }

    func observeTitle(_ title: String) {
        terminalTitle = title
    }

    func observeShellDirectory(_ directory: String?) {
        shellDirectory = directory
        if let directory, directory == pendingDirectorySync {
            pendingDirectorySync = nil
        }
    }

    // MARK: - private

    private func setFontSizeIndex(_ index: Int) {
        let clamped = min(max(index, 0), terminalFontSizes.count - 1)
        guard clamped != fontSizeIndex else { return }
        fontSizeIndex = clamped
        fontSize = terminalFontSizes[clamped]
        if let view { applyFont(to: view) }
    }

    private func scheduleLaunch() {
        guard !launchAttempted, launchFallback == nil, workspaceRoot != nil, view != nil else { return }
        // 主路径是 `observeSize`（SwiftUI 一布局就会到）。这里留个兜底：
        // 400ms 后还没收到尺寸，就直接问视图要 —— `terminalDimensions` 是公开 API，
        // 拿到的一样是真实行列数，不是估算值。
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.launchAttempted, let root = self.workspaceRoot else { return }
            self.launchFallback = nil
            let size = self.view?.terminalDimensions
            self.launch(root: root, columns: size?.cols ?? 80, rows: size?.rows ?? 25)
        }
        launchFallback = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func launch(root: URL, columns: Int, rows: Int) {
        guard !launchAttempted else { return }
        launchAttempted = true
        launchFallback?.cancel()
        launchFallback = nil

        // 视图的初始网格是 4x4（刻意的，见 TerminalCanvas），所以第一次布局一定
        // 会触发 sizeChanged —— 不必猜尺寸。
        let profile = TerminalProfile.standard(
            workingDirectory: root,
            columns: columns,
            rows: rows,
            programName: "CogniTerm",
            programVersion: Self.programVersion
        )
        let generation = pump.begin()
        let sink = pump
        let terminal = PseudoTerminal()
        terminal.onOutput = { data in
            sink.feed(data, generation: generation)
        }
        terminal.onExit = { [weak self] code in
            Task { @MainActor in self?.shellExited(code: code, generation: generation) }
        }

        do {
            try terminal.launch(profile.ptyConfig(
                workingDirectory: root, columns: columns, rows: rows
            ))
            pty = terminal
            status = .running(shell: profile.executablePath)
        } catch {
            pty = nil
            status = .failed(message: "\(error)")
            view?.feed(text: "\r\n\u{1b}[31m无法启动 \(profile.executablePath)：\(error)\u{1b}[0m\r\n")
        }
    }

    private func stop() {
        // 先作废旧代际，再杀进程：否则旧 shell 退出时残留的输出会混进新会话。
        pump.begin()
        pty?.terminate()
        pty?.forceKill()
        pty = nil
    }

    private func shellExited(code: Int32, generation: Int) {
        // 被 restart 顶掉的旧 shell：它的 onExit 会晚到，必须丢。
        guard generation == pump.current else { return }
        pty = nil
        status = .exited(code: code)
        view?.feed(text: "\r\n\u{1b}[2m[shell 已退出，退出码 \(code)]\u{1b}[0m\r\n")
    }

    private func abbreviatingHome(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static var programVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? ""
    }
}

/// TerminalSession 即 MCP 工具的执行平面（协议定义在 TerminalMCPServer.swift）。
extension TerminalSession: TerminalCommandExecutor {}

// MARK: - 终端视图

/// 只为一件事存在：点一下就把键盘焦点交给终端。
///
/// 上游 `mouseDown` 不保证会 `makeFirstResponder`,而"点了打不了字"正是老版最刺眼
/// 的毛病之一。`TerminalView` 是 `open class`、`mouseDown` 是 `open override`，
/// 用公开的继承点补上，不碰内部实现。
final class CogniTerminalView: TerminalView {
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// 焦点进出 → 发布给菜单栏用。
    ///
    /// 终端的快捷键走**宿主菜单**而不是覆盖 `performKeyEquivalent`：后者在
    /// SwiftTerm 里是 `public override`（非 open），模块外禁覆盖；而且上游在
    /// `keyDown` 里明写 "The host menu owns its shortcuts" —— 带 Command 的键
    /// 它会先问一次 `NSApp.mainMenu?.performKeyEquivalent`，菜单接了就不再发给
    /// shell。所以正确做法就是装菜单项，让 AppKit 的既有机制干活。
    ///
    /// 焦点状态不能省：⌘K/⌘R 这类键在聊天输入框里也按得到，不区分焦点就会
    /// 在用户根本没看终端时把终端清屏/重启。
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { TerminalFocus.shared.setFocused(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { TerminalFocus.shared.setFocused(false) }
        return accepted
    }
}

struct TerminalCanvas: NSViewRepresentable {
    @ObservedObject var session: TerminalSession
    var colorScheme: ColorScheme

    /// 初始网格刻意给一个**不可能等于真实面板尺寸**的值（4x4）。
    ///
    /// `TerminalView.setupOptions` 只在视图尺寸为 0 时用 startupOptions，否则直接按
    /// 像素算出真实行列数；而 `processSizeChange` 只在行列数**变化**时才回调
    /// `sizeChanged`。给 4x4 就保证了首次真实布局必然触发一次回调 —— 于是不需要
    /// 任何字符宽高估算（老代码里硬编码的 `charWidth=6.6` / `lineHeight=13.2`
    /// 与实际字体无关，行列数一直是错的）。
    private static var startupOptions: TerminalOptions {
        var options = TerminalOptions(cols: 4, rows: 4)
        options.scrollback = terminalScrollbackLines
        return options
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) {
            self.session = session
        }

        /// 键盘/鼠标编码 → PTY。方向键、Tab、Ctrl-R、Ctrl-C、粘贴全走这条路。
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(data)
        }

        /// 视图尺寸 → TIOCSWINSZ。全屏程序（vim/less/htop）靠它正确重排。
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.observeSize(columns: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            session.observeTitle(title)
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            session.observeShellDirectory(directory)
        }

        /// 滚动位置 → 回看状态。不在底部时界面浮出"回到底部"并统计新输出。
        func scrolled(source: TerminalView, position: Double) {
            session.observeScroll(position: position)
        }

        /// BEL（`\a`）。SwiftTerm 默认 `NSSound.beep()`，改成视觉提示。
        func bell(source: TerminalView) {
            session.observeBell()
        }

        /// OSC 52：程序（vim / tmux / 嵌套 ssh）请求把内容写进宿主的剪贴板。
        ///
        /// SwiftTerm 的默认实现是**空操作** —— 不实现这条时 OSC 52 全线静默失败，
        /// 表现为"在 vim 里 yy 了但粘贴板里什么都没有"，而且没有任何报错。
        /// Terminal.app / iTerm2 默认都放行写方向（本地程序写本地剪贴板，
        /// 与用户自己 `pbcopy` 无异）。读方向（`clipboardRead`）保持默认的
        /// 拒绝：让远端程序读本地剪贴板需要用户显式同意，不能默认开。
        func clipboardCopy(source: TerminalView, content: Data) {
            guard let text = String(data: content, encoding: .utf8) else {
                session.noteDiagnostic("[terminal] OSC 52 收到非 UTF-8 内容，已忽略（\(content.count) 字节）")
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }

        /// 只在 `notifyUpdateChanges` 为真时才回调，我们不开启它。
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        // 其余（requestOpenLink / bell / clipboardCopy / clipboardRead / kitty* /
        // programStatusChanged）都用上游默认实现：默认实现里 requestOpenLink
        // 走 NSWorkspace 打开链接，正是我们要的行为。
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> TerminalView {
        let view = CogniTerminalView(
            frame: .zero,
            font: NSFont.monospacedSystemFont(ofSize: session.fontSize, weight: .regular),
            options: Self.startupOptions
        )
        view.terminalDelegate = context.coordinator
        session.attach(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        session.applyFont(to: view)
        session.applyNativeColors(to: view)
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        nsView.terminalDelegate = nil
        coordinator.session.detach()
    }
}

// MARK: - 面板

struct TerminalPanel: View {
    @ObservedObject var session: TerminalSession
    /// 「在终端运行」捕获到输出后的回喂动作（由 MainSplitView 接走发 prompt）。
    /// 与审批卡的「在终端运行」共用同一出口：命令是审批卡注入的，但收敛时机
    /// （静默/立即回喂/跳过）在终端浮层上决定。
    var onRunCapture: (String) -> Void = { _ in }
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack(alignment: .bottomTrailing) {
                TerminalCanvas(session: session, colorScheme: colorScheme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if session.isViewingHistory {
                    backToBottomPill
                        .padding(10)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            // 「在终端运行」的状态浮层：注入中给「跳过/立即回喂」，
            // 收敛后确认一声。命令可能几分钟不静默（vim/ssh），不能没有出口。
            if case .running(let command) = session.runState {
                runStateBar(command: command)
            } else if case .captured(let lines) = session.runState {
                capturedBar(lines: lines)
            }
            if !session.status.isRunning {
                Divider()
                stoppedBar
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: session.isViewingHistory)
    }

    /// 注入执行中：显示命令摘要 + 两个出口（不等静默直接回喂 / 丢弃不回喂）。
    private func runStateBar(command: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("已在终端运行：\(command)")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("立即回喂") { session.flushRunCapture(onCapture: onRunCapture) }
                .controlSize(.small)
            Button("跳过") { session.skipRunCapture() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    /// 已回喂确认。3 秒后自动收起（和 bell 提示同款的短反馈）。
    private func capturedBar(lines: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.circle.fill")
                .foregroundStyle(.green)
            Text("已把终端输出（\(lines) 行）回喂给 agent")
                .font(.caption)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.green.opacity(0.10))
        .task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            session.dismissCaptured()
        }
    }

    /// 翻看历史时浮出的"回到底部"。带未读计数 —— `tail -f` / 长构建时，
    /// 用户在上面翻文档，根本不知道身后又刷了一屏。
    private var backToBottomPill: some View {
        Button { session.scrollToBottom() } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line")
                Text("回到底部")
                if session.unseenOutputChunks > 0 {
                    Text("\(session.unseenOutputChunks)")
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("回到输出末尾（也可以用滚轮向下滚到底）")
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            Label(session.terminalTitle.isEmpty ? "本地 shell" : session.terminalTitle,
                  systemImage: session.bellActive ? "bell.fill" : "terminal")
                .font(.caption.bold())
                .foregroundStyle(session.bellActive ? Color.orange : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(toolbarHelp)

            Text(session.statusText)
                .font(.caption2)
                .foregroundStyle(session.status.isRunning ? .secondary : .tertiary)
                .lineLimit(1)

            if let directory = session.directoryText {
                Text(directory)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            if let hint = session.syncHint() {
                Text("工作区已切换")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(hint)
            }

            // 选区 → agent：把选中的终端输出塞进输入框（VS Code「Add to Chat」同款）。
            // 常显不禁用：SwiftTerm 的选区变化没有委托可订阅，点击时若无选区
            // 会走诊断提示——比做一个永远不更新的 disabled 按钮好。
            icon("text.quote", help: "把选中的终端输出引用给 agent（先选中文本）· ⌘I", enabled: true) {
                session.askAgentWithSelection()
            }
            // 当前屏幕 → agent：懒得拖选时，把眼睛正看着的这一屏发出去。
            icon("rectangle.on.rectangle",
                 help: "把当前屏幕最近 50 行输出引用给 agent（⌘I 是发手选内容）· ⌘⇧I",
                 enabled: true) {
                session.sendScreenToAgent()
            }
            icon("arrow.turn.down.right",
                 help: "把终端切到工作区目录",
                 enabled: session.status.isRunning,
                 highlighted: session.pendingDirectorySync != nil) {
                session.syncWorkingDirectory()
            }
            icon("magnifyingglass", help: "查找（在回看缓冲里搜索）· ⌘F", enabled: true) {
                session.showFind()
            }
            icon("eraser", help: "清屏并清空回看缓冲 · ⌘K", enabled: session.status.isRunning) {
                session.clearScreen()
            }
            icon("stop.circle", help: "发送 Ctrl-C · ⌘.", enabled: session.status.isRunning) {
                session.interrupt()
            }
            icon("doc.on.doc", help: "复制选中内容 · ⌘C", enabled: true) {
                session.copySelection()
            }
            icon("doc.on.clipboard", help: "粘贴 · ⌘V", enabled: session.status.isRunning) {
                session.paste()
            }
            icon("textformat.size.smaller", help: "缩小字号 · ⌘-", enabled: true) {
                session.zoomOut()
            }
            icon("textformat.size.larger", help: "放大字号 · ⌘+", enabled: true) {
                session.zoomIn()
            }
            icon("arrow.clockwise", help: "重启 shell · ⌘R", enabled: true) {
                session.restart()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    /// 标题的提示：把可用的快捷键一次性列清楚。
    /// "难用"的一大来源是功能藏在图标里、 discoverability 为零。
    private var toolbarHelp: String {
        var lines = [
            "本地 shell（\(session.statusText)）",
            "⌘K 清屏 · ⌘F 查找 · ⌘R 重启 shell",
            "⌘. 中断 · ⌘+ / ⌘- / ⌘0 字号",
            "⌘C / ⌘V / ⌘A 复制粘贴全选（终端聚焦时）",
        ]
        if let directory = session.directoryText {
            lines.insert("目录：\(directory)", at: 1)
        }
        if !session.diagnostics.isEmpty {
            lines.append("诊断：" + session.diagnostics.suffix(3).joined(separator: " / "))
        }
        return lines.joined(separator: "\n")
    }

    private var stoppedBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(session.statusText)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("重启 shell") { session.restart() }
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func icon(
        _ name: String,
        help: String,
        enabled: Bool,
        highlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .frame(width: 20, height: 18)
                .foregroundStyle(highlighted ? Color.orange : Color.secondary)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .help(help)
    }
}
