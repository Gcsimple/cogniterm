import SwiftUI
import AppKit
import TerminalCore
import SwiftTerm
import PolicyEngine

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
final class TerminalSession: ObservableObject, Identifiable {

    enum Kind: Equatable {
        case local
        /// SSH 远程会话：PTY 的子进程是 `/usr/bin/ssh`（见 `TerminalProfile.ssh`）。
        case ssh
    }

    /// 本地会话的进程内唯一实例。
    ///
    /// 快捷键是 **Scene 级 `Commands` 菜单项**，而菜单在 `App` 上、拿不到
    /// `MainSplitView` 里的 `@StateObject`。侧栏会话列表出现之前，本地会话
    /// 就是"那个终端"，菜单通过它（或 SessionManager 的活跃会话）干活。
    /// SSH 会话由 `SessionManager` 创建，不走这个单例。
    static let shared = TerminalSession(kind: .local, label: "本地")

    /// 会话身份。会话切换与 MCP 目标标注都靠它。
    let id = UUID()
    let kind: Kind
    /// 侧栏与审批卡上的展示名：本地 = 「本地」，SSH = user@host。
    private(set) var label: String
    /// 远端目标（nil = 本地 shell）。
    private(set) var sshTarget: SSHTarget?
    /// 已保存的登录密码（**仅内存**；来源是 Keychain，由 `SessionManager` 建会话时读一次）。
    ///
    /// 唯一用途是「连接时自动填入」：不落盘、不进日志、不进宠物输入缓冲
    /// （所以注入走 `pty.write` 而不是 `send`）。
    private(set) var savedPassword: String?
    /// 这一次连接是否已经自动填过密码。
    ///
    /// 一次连接最多填一次：密码错了要让用户接手，而不是拿同一个错密码
    /// 去撞服务端的 max attempts（撞多了是账号锁定，不是输错密码）。
    private var didAutoFillPassword = false

    init(kind: Kind,
         label: String,
         sshTarget: SSHTarget? = nil,
         remoteDirectory: String? = nil,
         password: String? = nil) {
        self.kind = kind
        self.label = label
        self.sshTarget = sshTarget
        self.remoteWorkingDirectory = remoteDirectory
        self.savedPassword = password
    }

    /// 「不指定就本地」的便利构造。
    ///
    /// 会话多态化之前 `TerminalSession()` 是唯一构造方式，测试里有十来处这么写。
    /// 留着它比让每个测试各自抄一遍 `kind: .local, label: "本地"` 更不容易抄错，
    /// 而且语义明确：**只有本地会话可以无参构造**，SSH 必须说清目标。
    convenience init() {
        self.init(kind: .local, label: "本地")
    }

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
    /// **远程执行目录**（仅 SSH 会话有意义）：agent 的 `run_in_terminal` 会在
    /// 这个目录里执行，用户也可以在这里选。
    ///
    /// 为什么不复用 `workspaceRoot`：那个是 agent 的**本地**文件域，同时也是
    /// sidecar 沙箱边界（`-D WORKSPACE_ROOT=`）与 `WorkspaceFileReader` 的读边界，
    /// 三处都必须是本地路径。SSH 会话里「命令在哪跑」和「文件工具看哪儿」本来
    /// 就是两件事，硬塞进同一个变量会把沙箱边界一起带歪。
    ///
    /// nil = 用户还没指定。此时不注入任何 `cd`，让命令落在远程登录目录——
    /// **不猜**（猜错比不猜更糟：agent 会拿到一屏看似合理的错目录内容）。
    @Published private(set) var remoteWorkingDirectory: String?

    /// 远程执行目录变了（值真的变了才触发）。`SessionManager` 用它重新落盘
    /// 终端现场——否则用户设的目录重启就丢，而"重启回到登录目录"正是这个
    /// 功能最容易被骂的地方。
    var onRemoteDirectoryChanged: (() -> Void)?
    /// 「在终端运行」的运行时状态。审批卡出口见 `runCommandCaptured`。
    @Published private(set) var runState: TerminalRunState = .idle
    @Published private(set) var fontSize: CGFloat = terminalFontSizes[defaultTerminalFontSizeIndex]
    /// 工作区切走了，但终端还停在旧目录。非 nil 时工具条上的同步按钮会高亮。
    @Published private(set) var pendingDirectorySync: String?
    /// 远程执行目录变了，但远端 shell 还没 `cd` 过去（终端正忙 / 没起来）。
    /// 与 `pendingDirectorySync` 分开：那是本地工作区，这是远程目录，两边
    /// 的"跟进"是两件不同的事。
    @Published private(set) var pendingRemoteDirectorySync: String?
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

    /// 「用户现在这一行打了什么」的影子缓冲区（宠物用它做实时补全）。
    /// 由 `send` 唯一喂入，所以任何写进 PTY 的字节都会被计入。
    @Published private(set) var petInput = PetInputBuffer()

    /// 宠物当前给出的候选（已标好风险）。计算放在会话里而不是视图里：
    /// 行内灰字和工具栏气泡读的是同一份结果，不会出现「灰字补 A、气泡
    /// 第一名是 B」。
    @Published private(set) var petSuggestions: [PetSuggestion] = []

    /// 贴在光标后面的行内灰字内容（仅追加部分）。nil = 不显示。
    @Published private(set) var petGhostSuffix: String?

    /// `cwd` 下的条目名（目录带尾部 `/`），随目录变化重载一次。
    @Published private(set) var petEntries: [String] = []

    /// 打字时该不该**主动**展开候选面板。
    ///
    /// 算在会话里而不是视图里，原因很具体：最外层 overlay 靠 `anchorPreference`
    /// 拿鱼的位置，而那个闭包只在**布局**变化时重算——把随输入变化的 bool
    /// 一起塞进去，它会永远停在首帧（实测 `visible` 恒为 false，面板从不出现）。
    /// 走 @Published 才能让 overlay 跟着刷新。
    @Published private(set) var petAutoPanelVisible = false

    /// 完整气泡（点鱼打开的 popover）是否开着。由视图同步进来：
    /// 「气泡开着时面板让位」要算进上面的判定，否则会叠两层。
    @Published var petPopoverPresented = false {
        didSet {
            guard petPopoverPresented != oldValue else { return }
            recalcPetAutoPanelVisibility()
        }
    }

    /// 风险候选的「第二次点击」武装状态。气泡和自动面板共用 —— 同一条
    /// 风险命令在两个地方看到的风险态度必须一致。行内容一变就撤防。
    @Published var petArmedCommand: String?

    /// 自动面板被用户在**当前行**手动关过（× 或 Esc）。换新行（行清空）
    /// 后自动复位：下一行该弹还弹，不记仇。
    @Published private(set) var petAutoPanelDismissed = false

    /// 上一次重算候选时的行文本，用于「换行/改行」时复位交互状态。
    private var lastPetLine = ""

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
    private var petEntriesTask: Task<Void, Never>?

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

    /// 审批卡上的目标标注（「本地」/「user@host」）——多会话后必须说清命令
    /// 跑在哪个终端，否则用户无法分辨那是本地 shell 还是远程机器。
    var commandTargetDescription: String { label }

    /// 命令要落在哪台机器、哪个目录。审批卡、风险判定、agent 结果标注都读它。
    ///
    /// `directory` 对本地会话是工作区根，对远程会话是用户设定的远程目录
    /// （nil = 远程登录目录）。注意它**不是** `workspaceRoot`：远程会话下
    /// `workspaceRoot` 依然指向本地文件域，两者故意分开。
    var commandExecutionTarget: CommandExecutionTarget {
        CommandExecutionTarget(label: label,
                               directory: commandWorkingDirectory,
                               isRemote: kind == .ssh)
    }

    func start(root: URL) {
        guard workspaceRoot == nil else { return }
        workspaceRoot = root.standardizedFileURL
        reloadPetEntries()
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
        petEntriesTask?.cancel()
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
        // 远程会话与本地工作区无关：远端 cd 到本地路径毫无意义，不能提示同步。
        guard kind == .local else { return }
        pendingDirectorySync = pty == nil ? nil : standardized.path
    }

    func restart() {
        stop()
        launchAttempted = false
        pendingDirectorySync = nil
        // 重启后远端 shell 回到登录目录，而用户设定的执行目录还在——
        // 把差异摆到同步按钮上，别让它静默失配。
        pendingRemoteDirectorySync = kind == .ssh ? remoteWorkingDirectory : nil
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

    /// PTY 写入的**唯一低层漏斗**：键盘（`Coordinator.send`）、粘贴、
    /// 对话里代码块的「插入」、审批卡的「在终端运行」全部经过这里。
    /// 宠物因此不需要另铺一套钩子 —— 在这里顺手喂影子缓冲区，
    /// 就等价于「用户这一行打了什么」（见 `PetInputBuffer`）。
    func send(_ data: ArraySlice<UInt8>) {
        guard !data.isEmpty else { return }
        petInput.consume(data)
        pty?.write(Data(data))
        refreshPetSuggestions()
    }

    // MARK: 宠物补全

    /// 宠物眼里的「当前目录」：OSC 7 报了就信 shell，没报就退回工作区根。
    ///
    /// 远程会话回退到**远程**目录而不是本地工作区：宠物拿这个路径去列条目，
    /// 套一个本地路径进去只会在 SSH 会话里补出一堆本地目录名，敲下去全是
    /// `no such file`。（远程路径在本地列不出东西 → 空候选，这是正确降级：
    /// 宁可不给，不给错的。）
    private var petDirectory: String? {
        if kind == .ssh { return remoteWorkingDirectory ?? shellDirectory }
        return shellDirectory ?? workspaceRoot?.path
    }

    /// 键盘漏斗的**最前面**调用：这组字节如果是「接受行内灰字」的键，
    /// 返回应该替用户键入的补全尾巴；调用方据此截获、不把原字节发给 PTY。
    ///
    /// 三道闸：①必须是裸 Tab / 裸 →（修饰键组合不认）；②影子可信且不在
    /// 括号粘贴里；③确实有灰字可补。任何一条不满足都返回 nil，按键与从前
    /// 完全等价（Tab 照样落给 shell 自己的补全）。
    func petCompletion(forKey data: ArraySlice<UInt8>) -> String? {
        guard PetGhostKey.isAcceptKey(data),
              !petInput.isPasting,
              petInput.confidence.isExact,
              let suffix = petGhostSuffix,
              !suffix.isEmpty
        else { return nil }
        return suffix
    }

    /// 接受灰字：把尾巴当普通键入发出去（走 `send`，影子缓冲区随之精确更新），
    /// 依然**不回车**。
    func acceptPetCompletion(_ suffix: String) {
        send(ArraySlice(Array(suffix.utf8)))
    }

    /// 接受一条候选（气泡 / 自动面板共用）。风险命令第一次点击只武装、
    /// 不执行；第二次确认才整行替换。**不回车** —— 决定权在人手上。
    func acceptPetSuggestion(_ suggestion: PetSuggestion) {
        if suggestion.isRisky && petArmedCommand != suggestion.command {
            petArmedCommand = suggestion.command
            return
        }
        petArmedCommand = nil
        replaceCommandLine(suggestion.command)
    }

    /// 用户主动收起自动面板（× / Esc）：本行不再主动展开。
    func dismissPetAutoPanel() {
        petAutoPanelDismissed = true
        petAutoPanelVisible = false
    }

    /// 重算候选与行内灰字。每次输入后调用；目录条目是异步到的，到了再算一次。
    private func refreshPetSuggestions() {
        let input = petInput

        // 行变了：撤掉风险武装（上一条命令的「再点一次」不能带到下一条）；
        // 行清空（回车换新行）：解除「本行已关面板」。
        if input.text != lastPetLine {
            petArmedCommand = nil
            if input.text.isEmpty { petAutoPanelDismissed = false }
            lastPetLine = input.text
        }

        let resolved = PetSuggestionEngine.suggest(
            line: input.text,
            leadingContext: input.leadingContext,
            token: input.trailingToken,
            kind: input.confidence,
            entries: petEntries,
            history: PetContextStore.shared.history(),
            agentCommands: PetContextStore.shared.agentCommands
        ).map { suggestion in
            PetSuggestion(id: suggestion.id,
                          command: suggestion.command,
                          source: suggestion.source,
                          isRisky: isPetCommandRisky(suggestion.command))
        }
        petSuggestions = resolved
        petGhostSuffix = PetGhostCompletion.suffix(
            line: input.text,
            isExact: input.confidence.isExact,
            suggestions: resolved
        )
        recalcPetAutoPanelVisibility()
    }

    /// 面板可见性：纯策略 + 当前状态。输入、候选、气泡开关任何一处变了都重算。
    private func recalcPetAutoPanelVisibility() {
        petAutoPanelVisible = PetAutoPanelPolicy.isVisible(
            input: petInput,
            suggestions: petSuggestions,
            popoverPresented: petPopoverPresented,
            dismissed: petAutoPanelDismissed
        )
    }

    private func isPetCommandRisky(_ command: String) -> Bool {
        RiskEvaluator.assess(
            CommandInvocation(tool: "terminal",
                              command: command,
                              cwd: petDirectory,
                              workspaceRoot: workspaceRoot?.path)
        ).needsHumanApproval
    }

    /// cwd 一变（OSC 7 到达 / 工作区确定）就重新列一次目录。读盘放后台：
    /// 大目录列一次不便宜，不能堵在主线程的输入路径上。
    private func reloadPetEntries() {
        let directory = petDirectory
        petEntriesTask?.cancel()
        petEntriesTask = Task.detached { [weak self] in
            let loaded = PetContextStore.listEntries(at: directory)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.petEntries = loaded
                self.refreshPetSuggestions()
            }
        }
    }

    /// 把当前命令行**整行替换**成给定文本（宠物候选项的接受动作）。
    ///
    /// 先发 Ctrl-U 让 ZLE kill 掉整行，再键入新内容；**不回车**——
    /// 与代码块的「插入」同一个语义：东西落到命令行上，按不按 ↵ 由人决定。
    func replaceCommandLine(_ command: String) {
        guard !command.isEmpty else { return }
        send(ArraySlice([0x15]))
        send(ArraySlice(Array(command.utf8)))
        focusTerminal()
    }

    #if DEBUG
    /// 截图夹具：把一行文本**真的敲进 PTY**，等价于「用户刚敲完这行」。
    ///
    /// 走 `send` 而不是只喂影子缓冲区：终端上得真出现这行字，否则面板在建议
    /// `git status`、命令行却空着，图就假了。`send` 自己会喂缓冲区并重算候选。
    /// 宠物面板与行内灰字都是输入驱动的，而 UI 自动化在这台机器上被 TCC 挡死
    /// （`osascript … System Events` → -10004）。入口在 `MainSplitView` 的 `demoPetLine`。
    func injectDemoInput(_ text: String) {
        guard !text.isEmpty else { return }
        send(ArraySlice(Array(text.utf8)))
        focusTerminal()
    }
    #endif

    /// 把一条命令**键入**终端但不回车（对话里代码块的「插入」动作）。
    ///
    /// 语义刻意与「运行」分开：模型给的命令先落到命令行上，用户自己看一遍、
    /// 改完再按 ↵。这是审批之外的第二道人工闸——不花任何额外点击，
    /// 但人一定扫过一眼。
    ///
    /// 不校验 `isTerminalReady`：PTY 没起来时 `write` 本来就是 no-op，
    /// 而这里多一个静默返回会让「按钮点了没反应」变得更难查。
    func insertCommand(_ command: String) {
        guard !command.isEmpty else { return }
        send(ArraySlice(Array(command.utf8)))
        // 焦点交给终端：用户下一步就是按 ↵，不该再点一下。
        focusTerminal()
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
        ///
        /// SSH 会话额外补一句 `cd`：agent 给的命令文本里没有「在哪个目录执行」
        /// 这个信息（它以为的目录在远端，终端却可能停在别处）。不补这一层，
        /// 同一条 `ls` 会在两个不同的世界里执行，而 agent 拿到输出后**无从察觉**。
        /// 单行 / 多行的不同处理见 `RemoteCommand`（多行必须包进子 shell，
        /// 否则 `&&` 只管住第一行）。
        ///
        /// 注入的是加了前缀的文本，但 `runState` 里存的是**原始命令**——
        /// 浮层上要显示用户认得出的那条命令，不是带引号路径的长串。
        let injected = kind == .ssh
            ? RemoteCommand.withWorkingDirectory(remoteWorkingDirectory, command: command)
            : command
        let invocation = ShellCommand.submitted(injected)
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
    ///
    /// SSH 会话下这里的语义是「让远端 shell 跟进 `remoteWorkingDirectory`」——
    /// 旧实现直接 `guard kind == .local else { return }`，于是远程会话里这个
    /// 按钮点了毫无反应，而它恰恰是唯一能让「agent 执行目录」和「终端所在目录」
    /// 对齐的手动出口。
    func syncWorkingDirectory() {
        switch kind {
        case .local:
            guard let root = workspaceRoot, pty != nil else { return }
            let command = ShellCommand.submitted(ShellCommand.directoryChange(toAbsolutePath: root.path))
            pty?.write(Data(command.utf8))
            pendingDirectorySync = nil
        case .ssh:
            guard remoteWorkingDirectory != nil, status.isRunning else { return }
            syncRemoteShellIfPossible()
        }
    }

    // MARK: 远程执行目录（SSH）

    /// 当前会话的命令是否跑在远端。
    var isRemoteExecution: Bool { kind == .ssh }

    /// agent 的命令将落在哪个目录（本地是工作区，远程是用户设定的远程目录）。
    ///
    /// nil 在远程语义下表示"远程登录目录"——不是"不知道"，只是没显式设定。
    var commandWorkingDirectory: String? {
        kind == .ssh ? remoteWorkingDirectory : workspaceRoot?.path
    }

    /// 设定远程执行目录，并**立刻**让远端 shell 跟过去（用户显式确认过的动作，
    /// 与"工作区切换不自动 cd"不是一回事：那次是怕打断正在跑的前台程序，
    /// 这里是用户点名要进这个目录）。
    ///
    /// 终端正忙（有命令在跑 / 没起来）时不注入，改用 `pendingRemoteDirectorySync`
    /// 亮起工具条上的同步按钮——往一个正在跑的程序里打字比不跟进更糟。
    ///
    /// - Parameter path: 传 nil / 空串 = 取消设定（回到"远程登录目录"，不注入 cd）。
    func setRemoteWorkingDirectory(_ path: String?) {
        guard kind == .ssh else { return }
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized: String? = trimmed.isEmpty ? nil : trimmed
        let changed = remoteWorkingDirectory != normalized
        remoteWorkingDirectory = normalized
        if changed { onRemoteDirectoryChanged?() }
        guard normalized != nil else {
            pendingRemoteDirectorySync = nil
            return
        }
        // 值没变也照样尝试同步一次：终端可能被用户自己 cd 走了，
        // 「再说一遍用这个目录」是合理的意图。
        syncRemoteShellIfPossible()
    }

    /// 列举远程目录（选择器用）。只读探测，不碰 PTY、不打扰用户正在跑的命令。
    ///
    /// 复用已认证的通道（`controlSocketPath`）：探测走 `BatchMode`，它自己不会
    /// 认证、也不会等密码提示——不搭上 master 的话，「存了密码」的用户反而点不开
    /// 目录浏览，只会看到"该主机需要交互认证"。
    func listRemoteDirectories(
        at path: String,
        completion: @escaping @MainActor (Result<RemoteDirectoryListing, RemoteDirectoryError>) -> Void
    ) {
        guard let target = sshTarget else {
            completion(.failure(.unreachable("会话没有远端目标")))
            return
        }
        let socket = SSHConnectionSharing.socketPath(for: target,
                                                    directory: SSHControlDirectory.path)
        Task { @MainActor in
            do {
                let listing = try await RemoteDirectoryBrowser.list(target: target,
                                                                    path: path,
                                                                    controlSocketPath: socket)
                completion(.success(listing))
            } catch let error as RemoteDirectoryError {
                completion(.failure(error))
            } catch {
                completion(.failure(.unreachable("\(error)")))
            }
        }
    }

    /// 往远端 shell 注入 `cd`。
    ///
    /// 三道闸：会话是远程、用户确实设过目录、终端起来了且闲着。
    /// 任一不满足就把目标记进 `pendingRemoteDirectorySync`，让工具条上的
    /// 同步按钮亮起来——**留下一个可见的待办，而不是静默丢掉**。
    private func syncRemoteShellIfPossible() {
        guard kind == .ssh, let remote = remoteWorkingDirectory else { return }
        guard let pty, status.isRunning, !isCapturingCommand else {
            pendingRemoteDirectorySync = remote
            return
        }
        let command = ShellCommand.submitted(
            RemoteDirectoryBrowser.directoryChangeCommand(remote)
        )
        pty.write(Data(command.utf8))
        pendingRemoteDirectorySync = nil
    }

    /// ssh 停在密码提示上：把 Keychain 里存的密码填进去。
    ///
    /// 注入走 `pty?.write` 而**不是** `send`：`send` 会把字节同时喂给宠物的
    /// 影子命令行缓冲区，密码就会以明文出现在候选面板与行内灰字里。
    ///
    /// 填完 `didAutoFillPassword` 就锁死：密码错了要让人接手，重复拿错密码
    /// 去撞服务端的 max attempts 会把账号锁掉。
    private func autoFillPasswordIfPossible() {
        guard kind == .ssh,
              let password = savedPassword, !password.isEmpty,
              !didAutoFillPassword,
              let pty, status.isRunning else { return }
        didAutoFillPassword = true
        // ssh 把 tty 切到了 no-echo，屏幕上只会多一个换行。
        pty.write(Data((password + "\r").utf8))
        noteDiagnostic("[ssh] 已填入保存的登录密码（\(label)）")
    }

    /// 更新这一会话内存里的密码（Keychain 的写入由调用方负责）。
    ///
    /// 只改内存：新建 ssh 进程才会重新走一次认证，所以调用方通常紧接着
    /// `restart()`——不然用户会盯着一个已经连上（或已经失败）的旧连接发呆。
    func setSavedPassword(_ password: String?) {
        savedPassword = (password?.isEmpty ?? true) ? nil : password
        didAutoFillPassword = false
    }

    /// 会话切换后把键盘焦点交给这个终端（点击会话列表即可以开始打字）。
    func focusTerminal() {
        guard let view, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    // MARK: 展示

    /// 工具栏默认标题：远端显示 user@host，本地显示「本地 shell」。
    /// shell 通过 OSC 0/2 自报标题时优先用它的（见 `terminalTitle`）。
    var defaultTitle: String {
        kind == .ssh ? label : "本地 shell"
    }

    var statusText: String {
        switch status {
        case .idle: return "未启动"
        case .running(let shell):
            // SSH 的 status 存的是 user@host（连到哪了比"ssh"更有用）。
            return kind == .ssh ? shell : (shell as NSString).lastPathComponent
        case .exited(let code): return "已退出（\(code)）"
        case .failed(let message): return "启动失败：\(message)"
        }
    }

    /// 本地：优先显示 shell 自报的目录（OSC 7），没有就显示工作区根。
    ///
    /// 远程：显示**远程执行目录**（用户设定的那个），而不是本地工作区——
    /// 旧实现远程一律返回 nil，于是「命令到底在远端哪个目录跑」全 App 无处可见，
    /// 而这恰恰是 agent 与用户最容易对不上的一个事实。
    var directoryText: String? {
        switch kind {
        case .local:
            return abbreviatingHome(shellDirectory ?? workspaceRoot?.path)
        case .ssh:
            // 远程路径不能套本地家目录缩写：`/Users/x` 在远端几乎不存在。
            return remoteWorkingDirectory ?? shellDirectory
        }
    }

    func syncHint() -> String? {
        if let pending = pendingDirectorySync {
            return "工作区已切到 \(abbreviatingHome(pending) ?? pending)，点击让终端跟进"
        }
        if let pending = pendingRemoteDirectorySync {
            return "远程执行目录是 \(pending)，点击让远端 shell 跟进"
        }
        return nil
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
        let oldDirectory = petDirectory
        shellDirectory = directory
        if let directory, directory == pendingDirectorySync {
            pendingDirectorySync = nil
        }
        // 远程会话：远端 shell 自报目录（OSC 7，需要远端 shell 配置）时，
        // 若用户还没指定过执行目录，就**采纳它**——"终端在哪，agent 就按哪算"
        // 是这个功能的默认期待。已经指定过则不覆盖：用户显式选的值不该被
        // 一次 prompt 钩子悄悄改掉。
        if kind == .ssh, remoteWorkingDirectory == nil, let directory, !directory.isEmpty {
            remoteWorkingDirectory = directory
        }
        if kind == .ssh, let directory, directory == pendingRemoteDirectorySync {
            pendingRemoteDirectorySync = nil
        }
        if petDirectory != oldDirectory {
            reloadPetEntries()
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
        // SSH 会话：同一套 PTY 管线，只换子进程（见 `TerminalProfile.ssh`）。
        // 本地会话：login shell + 工作区 cwd。
        let profile: TerminalProfile
        if let sshTarget {
            profile = .ssh(
                sshTarget,
                // 连接复用：同一个目标在 10 分钟内只认证一次。这是「每次开
                // 标签都要重新输密码」的主解，而且完全不碰密码本身。
                controlSocketPath: SSHConnectionSharing.socketPath(
                    for: sshTarget,
                    directory: SSHControlDirectory.path
                ),
                programName: "CogniTerm",
                programVersion: Self.programVersion
            )
        } else {
            profile = TerminalProfile.standard(
                workingDirectory: root,
                columns: columns,
                rows: rows,
                programName: "CogniTerm",
                programVersion: Self.programVersion
            )
        }
        let generation = pump.begin()
        let sink = pump
        let terminal = PseudoTerminal()
        // 密码自动填充的探测器：只在 SSH 会话、且确实存过密码时才装。
        // 它跑在读线程（与输出泵同一个回调），命中密码提示后跳主线程写入。
        let probe = (sshTarget != nil && savedPassword != nil) ? PasswordPromptProbe() : nil
        terminal.onOutput = { data in
            sink.feed(data, generation: generation)
            if probe?.feed(data) == true {
                Task { @MainActor [weak self] in self?.autoFillPasswordIfPossible() }
            }
        }
        terminal.onExit = { [weak self] code in
            Task { @MainActor in self?.shellExited(code: code, generation: generation) }
        }
        // 新进程 = 新的一次认证机会。
        didAutoFillPassword = false

        do {
            try terminal.launch(profile.ptyConfig(
                workingDirectory: root, columns: columns, rows: rows
            ))
            pty = terminal
            // SSH 的 status 里存展示名（user@host），工具栏据此显示"连到哪了"。
            status = .running(shell: sshTarget?.displayName ?? profile.executablePath)
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

    /// 关会话（SessionManager 从列表移除后调用）：杀 PTY，状态归位。
    ///
    /// 与 `restart()` 的区别：这个不重启。本地会话不允许被关（它是 agent 的
    /// 默认执行平面），只有 SSH 会话会走到这里。
    func terminate() {
        stop()
        launchAttempted = false
        runState = .idle
        status = .idle
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

    /// 宠物行内灰字的载体。它是终端视图的子视图，但**永不参与命中测试**
    /// （`hitTest` 直接返回 nil）：选区、鼠标编码、点击聚焦全都透传给终端，
    /// SwiftTerm 自己的绘制/输入路径一行不碰。坐标取公开的 `caretFrame`
    /// ——当前 App 走主线程渲染路径，光标每帧都会更新它。
    private let ghostLabel = GhostCompletionLabel()
    private var ghostText: String?
    private var ghostTextWidth: CGFloat = 0
    private var ghostAttributes: [NSAttributedString.Key: Any] = [:]

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// 设置行内灰字内容；nil / 空串即隐藏。字号跟随终端当前字体，
    /// 字距按单元格宽度补差，保证灰字一格一格压在终端网格上。
    func setGhostCompletion(_ text: String?) {
        ghostText = text
        guard let text, !text.isEmpty else {
            ghostLabel.isHidden = true
            return
        }
        ensureGhostLabel()
        let font = self.font
        let kern = font.kernToFitCell(cellWidth: caretFrame.width)
        ghostAttributes = [
            .font: font,
            // tertiaryLabel 在深/浅外观下都是「能看见但绝不抢戏」的灰。
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: kern
        ]
        ghostLabel.attributedStringValue = NSAttributedString(string: text,
                                                              attributes: ghostAttributes)
        ghostTextWidth = (text as NSString).size(withAttributes: ghostAttributes).width
        positionGhostLabel()
        ghostLabel.isHidden = false
    }

    /// 终端缓冲每帧变化、滚动、尺寸变化时重定位（由 `rangeChanged` 等委托驱动）。
    /// 敲键后真正让光标挪位的是 shell 回显，那一刻不重贴就会落后一格。
    func refreshGhostPosition() {
        guard let ghostText, !ghostText.isEmpty, !ghostLabel.isHidden else { return }
        positionGhostLabel()
    }

    private func ensureGhostLabel() {
        if ghostLabel.superview !== self {
            addSubview(ghostLabel, positioned: .above, relativeTo: nil)
        }
    }

    private func positionGhostLabel() {
        let caret = caretFrame
        guard caret != .zero else {
            ghostLabel.isHidden = true
            return
        }
        let availableWidth = max(0, bounds.width - caret.maxX - 2)
        ghostLabel.frame = NSRect(
            x: caret.maxX,
            y: caret.minY,
            width: min(ghostTextWidth, availableWidth),
            height: caret.height
        )
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

/// 行内灰字专用 Label：透明背景、单行、超长裁切；最重要的是 `hitTest`
/// 返回 nil —— 它在视觉上盖着终端，交互上「不存在」，选区和鼠标编码不受影响。
private final class GhostCompletionLabel: NSTextField {

    init() {
        super.init(frame: .zero)
        isBezeled = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        // 不能置成 isEnabled=false：禁用态文本会被系统改色，灰字颜色必须由我们控制。
        isHidden = true
        usesSingleLineMode = true
        cell?.wraps = false
        lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private extension NSFont {
    /// SwiftTerm 把单元格宽度做了像素取整，等宽字体的自然推进可能略窄，
    /// 差值作为字距补上（与 SwiftTerm 输入法浮层同款算法）。
    func kernToFitCell(cellWidth: CGFloat) -> CGFloat {
        guard cellWidth > 0 else { return 0 }
        let natural = advancement(forGlyph: glyph(withName: "W")).width
        return max(0, cellWidth - natural)
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
            // 最前面一道闸：裸 Tab / 裸 → 且行内灰字正在显示时截获，
            // 把补全尾巴「替用户键入」（不回车）；其余一切原样透传。
            if let suffix = session.petCompletion(forKey: data) {
                session.acceptPetCompletion(suffix)
                return
            }
            session.send(data)
        }

        /// 视图尺寸 → TIOCSWINSZ。全屏程序（vim/less/htop）靠它正确重排。
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.observeSize(columns: newCols, rows: newRows)
            (source as? CogniTerminalView)?.refreshGhostPosition()
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
            (source as? CogniTerminalView)?.refreshGhostPosition()
        }

        /// 终端可见缓冲变化（shell 回显让光标真正挪位的时机）→ 灰字跟着光标走。
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
            (source as? CogniTerminalView)?.refreshGhostPosition()
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
        // 打开可见变化回调：行内灰字靠 rangeChanged 追光标的每帧位置。
        view.notifyUpdateChanges = true
        session.attach(view)
        return view
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        session.applyFont(to: view)
        session.applyNativeColors(to: view)
        (view as? CogniTerminalView)?.setGhostCompletion(session.petGhostSuffix)
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
    /// 远程目录选择器（只有 SSH 会话会置 true）。
    @State private var showRemoteDirectory = false
    /// 登录密码设置（只有 SSH 会话会置 true）。
    @State private var showPasswordSheet = false

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
        // 远程目录选择器挂在终端面板上（而不是 MainSplitView 的中央 sheet 路由）：
        // 它天然属于"这个会话"，切换标签后不该还挂着一个别的会话的选择器。
        .sheet(isPresented: $showRemoteDirectory) {
            RemoteDirectorySheet(session: session)
        }
        .sheet(isPresented: $showPasswordSheet) {
            SSHPasswordSheet(session: session)
        }
        // 胖鱼打字时主动展开的候选面板：鱼只上报锚点，可见性由
        // `session.petAutoPanelVisible` 广播（原因见该属性的注释）。
        // 面板在最外层渲染，盖在终端 NSView 之上、钉在鱼身下沿。
        // 窗口内 SwiftUI 视图，不改变 firstResponder —— 键盘输入全程留在终端。
        .overlayPreferenceValue(PetPanelAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if session.petAutoPanelVisible, let anchor {
                    let fishRect = proxy[anchor]
                    let panelWidth: CGFloat = 320
                    // 右缘与鱼对齐，空间不够（窗口窄）时向左收，始终留 8pt 边。
                    let x = min(max(8, fishRect.maxX - panelWidth),
                                proxy.size.width - panelWidth - 8)
                    PetAutoPanel(
                        suggestions: Array(session.petSuggestions.prefix(5)),
                        ghostCommand: session.petGhostSuffix.map { session.petInput.text + $0 },
                        armedCommand: session.petArmedCommand,
                        onAccept: { session.acceptPetSuggestion($0) },
                        onDismiss: { session.dismissPetAutoPanel() }
                    )
                    .frame(width: panelWidth)
                    .offset(x: x, y: fishRect.maxY + 6)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .animation(.easeOut(duration: 0.12), value: session.petAutoPanelVisible)
        }
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
            // 会话身份已经由上方标签栏（TerminalTabBar）承担，这里不再重复
            // 「本地 shell / user@host」——只留「跑的是什么 shell、在哪个目录」，
            // 也就是标签栏答不出来的那部分。
            Image(systemName: session.kind == .ssh ? "network" : (session.bellActive ? "bell.fill" : "terminal"))
                .font(.caption2)
                .foregroundStyle(session.bellActive ? Color.orange : (session.kind == .ssh ? Color.blue : Color.secondary))
                .help(toolbarHelp)

            Text(session.statusText)
                .font(.caption2)
                .foregroundStyle(session.status.isRunning ? .secondary : .tertiary)
                .lineLimit(1)

            if session.kind == .ssh {
                remoteDirectoryButton
            } else if let directory = session.directoryText {
                Text(directory)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 8)

            // 宠物跟着工具栏走：工具栏是确定性布局的一行，比在画布上开
            // 浮层省掉一堆对齐坑（曾试过 ZStack bottomTrailing，气泡一展开
            // 宠物就漂到半空）。
            PetOverlayView(session: session)

            if let hint = session.syncHint() {
                Text("工作区已切换")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(hint)
            }

            // 登录密码：只在 SSH 会话出现。图标状态直接反映"这台主机存没存密码"，
            // 因为"为什么这次没自动填"是用户第一个会问的问题。
            if session.kind == .ssh {
                icon("key.fill",
                     help: session.savedPassword == nil
                         ? "登录密码未保存：每次连接都要手动输入 · 点击设置"
                         : "已保存登录密码，连接时自动填入 · 点击修改或清除",
                     enabled: true,
                     highlighted: session.savedPassword == nil) {
                    showPasswordSheet = true
                }
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

    /// SSH 会话的「远程执行目录」入口。
    ///
    /// 必须可点：本地会话里目录是 agent 文件域的**结果**（改它要走侧栏），
    /// 而远程会话里「命令在哪个目录跑」是用户随时要能改的东西——否则 SSH
    /// 会话永远停在登录目录，而 agent 以为自己在项目里。
    private var remoteDirectoryButton: some View {
        Button { showRemoteDirectory = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(session.remoteWorkingDirectory ?? "选择远程目录")
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .foregroundStyle(session.remoteWorkingDirectory == nil ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(session.remoteWorkingDirectory == nil
              ? "还没指定远程执行目录：agent 的命令会落在远程登录目录。点这里选一个"
              : "agent 的命令在这个远程目录里执行 · 点击更改")
    }

    /// 标题的提示：把可用的快捷键一次性列清楚。
    /// "难用"的一大来源是功能藏在图标里、 discoverability 为零。
    private var toolbarHelp: String {
        var lines = [
            // 远程会话写「本地 shell」是错的：这个提示是用户确认"我在哪台机器上"
            // 的最后一道，写错了比不写更糟。
            session.kind == .ssh ? "SSH \(session.label)（\(session.statusText)）"
                                 : "本地 shell（\(session.statusText)）",
            "⌘K 清屏 · ⌘F 查找 · ⌘R 重启 shell",
            "⌘. 中断 · ⌘+ / ⌘- / ⌘0 字号",
            "⌘C / ⌘V / ⌘A 复制粘贴全选（终端聚焦时）",
        ]
        if session.kind == .ssh {
            lines.insert("agent 执行目录：" + (session.remoteWorkingDirectory ?? "远程登录目录（未指定）"),
                         at: 1)
        } else if let directory = session.directoryText {
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

/// 密码提示探测器的线程安全外壳。
///
/// PTY 输出在读线程回调，主线程同时在判「该不该填」——探测器本身是个可变
/// struct，直接跨线程用就是数据竞争。这里只做一把锁，不引入任何策略
/// （判定规则全在 `PasswordPromptDetector` 里，纯函数、可单测）。
private final class PasswordPromptProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var detector = PasswordPromptDetector()

    /// 返回 true 表示这一屏停在密码提示上。
    func feed(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return detector.feed(data)
    }
}

