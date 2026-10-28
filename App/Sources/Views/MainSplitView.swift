import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData
import AcpClient
import PolicyEngine
import Persistence
import SessionLogReader
import TerminalCore

struct MainSplitView: View {
    @StateObject private var sidecar = SidecarService.shared
    @StateObject private var conversation = ConversationModel()
    // shared 而不是自建实例：菜单项（Scene 级 Commands）够不到这里的 @StateObject，
    // 两边的实例不一致时菜单操作的和界面上显示的不是同一个会话。
    /// 终端会话集合（本地 + SSH）。终端面板与 agent 执行平面都指向它的活跃会话。
    @ObservedObject private var sessions = SessionManager.shared
    /// 本地会话：只有它的 cwd（OSC 7）与工作区是同一个坐标系，其余同步逻辑仍指它。
    @ObservedObject private var terminal = TerminalSession.shared
    /// 新建 SSH 会话表单。
    @State private var showNewSSHSession = false
    /// DEBUG 夹具：设置窗口没起来时的兜底弹层（只由 `demoSettingsOnLaunch` 打开）。
    @State private var demoSettingsSheet = false
    /// 菜单/快捷键下发的一次性指令（Scene 级 `Commands` 够不到本视图的 `@State`）。
    @ObservedObject private var appCommands = AppCommandCenter.shared
    /// 终端 MCP server（agent 的 run_in_terminal 执行平面）。观察它是为了让
    /// 侧栏那行端点状态在监听成功/失败时自动刷新。
    @ObservedObject private var terminalMCP = TerminalMCPServer.shared

    @Environment(\.modelContext) private var modelContext
    /// 工作区路径。**持久化**（旧实现是 @State：用户选的工作区每次重启都丢，
    /// 静默重置回 $HOME，而 agent 的 glob 扫整个 home 必炸——TCC EPERM +
    /// 30s 超时，2026-10-17 用 5 个失败会话实证）。空串 = 首启，.task 里落默认值。
    @AppStorage("workspacePath") private var workspacePath: String = ""
    @State private var showDiagnostics = false
    @State private var replay: ReplayItem?
    /// 终端面板高度（**用户拖过分隔条之后**的值）。`0` = 自适应（默认）。
    ///
    /// 旧版是个写死的 220pt——那 220 里 56pt 是标签栏 + 工具条，只剩 164pt 给终端，
    /// 默认字号 12pt 一格 15pt，也就是**不到 11 行**，敲一条 `git status` 就得开滚。
    /// 现在默认走 `TerminalPanelSizing.idealHeight`：行数下限 + 窗口比例取大者，
    /// 跟着窗口高度和字号一起长。用户拖过一次就记绝对值（语义变成"我就要这么高"），
    /// 拖柄右键能恢复自适应。
    @AppStorage("terminalPanelHeight") private var customTerminalHeight: Double = 0
    /// 终端面板折叠态（⌘J / 双击分隔条 / 收起条上的展开按钮）。
    /// 折叠不是删除：高度记忆在 terminalHeight 里，展开即恢复。
    /// 「只想专心聊天」时把默认 220pt 整个还给对话区——旧实现最小 120pt，
    /// 终端永远杵在那儿抢空间。
    @AppStorage("terminalPanelCollapsed") private var terminalPanelCollapsed = false
    /// 拖拽中的起始高度（见 terminalResizeHandle）。
    @State private var heightAtDragStart: Double = 0
    @State private var isDraggingHeight = false
    /// 最近一次「在终端运行」的命令——浮层「立即回喂」时要知道回喂哪条。
    @State private var pendingTerminalCommand: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        .task {
            sidecar.conversation = conversation
            // 首启：落默认工作区 ~/CogniTerm（不存在则创建）。
            if workspacePath.isEmpty {
                workspacePath = SidecarService.defaultWorkspaceURL().path
            }
            // 旧版路径输入框把 `log` 解析成 `$HOME/log` 留下的残留，见 WorkspacePaths。
            var repaired = workspacePath
            if WorkspacePaths.repairLegacyResidue(&repaired) {
                workspacePath = repaired
                conversation.appendSystem("工作区已从 ~/log 恢复到默认的 ~/CogniTerm（旧版路径输入框的遗留值，改一次即记住）")
            }
            conversation.workspaceRoot = workspacePath
            // ⚠️ sidecar.workspaceRoot 必须在这里显式赋值。旧实现只在 applyWorkspace()
            // 里设它，首启时保持字段默认值 $HOME——于是 sidebar 里显示的路径和
            // sidecar 真正的 WORKSPACE_ROOT（以及 dsh 内层 sandbox 的 workspaceRoot，
            // 它取 process.cwd()）**永远是两个东西**，而用户问「当前目录有什么文件夹」
            // 时 agent 扫的就是整个 $HOME（2026-10-17 实证：5 次尝试全败）。
            sidecar.workspaceRoot = URL(fileURLWithPath: workspacePath)
            loadRules()
            loadSettings()
            terminal.start(root: URL(fileURLWithPath: workspacePath))
            // 恢复上次的终端现场（手开的 SSH 标签）。放在 start 之后：
            // 本地 shell 先起来，恢复出来的远程标签排在它后面。
            // 只做一次，重复调用是幂等的（SessionManager 内部有 didRestore 标记）。
            sessions.restoreWorkspaceIfNeeded(root: FileManager.default.homeDirectoryForCurrentUser)
            // 终端 MCP server：agent 的 run_in_terminal 工具经它在我们的 PTY 上
            // 执行（审批门 = conversation，执行平面 = SessionManager 的活跃会话）。
            // sidecar.start() 会在 session/new 前启动它并注册 mcpServers；这里先把依赖接好。
            let mcp = TerminalMCPServer.shared
            mcp.gate = conversation
            // 多会话后执行平面是「当时的活跃会话」：SessionManager 委托 + 审批卡
            // 标注目标（本地 / user@host），见 SessionManager 的 executor 扩展。
            mcp.executor = sessions
            // 值捕获（MainSplitView 是 struct，无法 weak）：捕获到的都是 app 级
            // 长生命周期对象（sidecar/conversation 单例或随窗口存活），强持有无泄漏。
            // 迟到的输出（超过 55s 窗口才收敛的命令）经这里回喂成一次 prompt。
            mcp.onLateOutput = { command, output in
                self.feedTerminalOutputBackToAgent(command: command, output: output)
            }
            // 零配置：自动播种 profile，有 Key 直连，无 Key 弹一次引导。
            await sidecar.bootstrap()

            #if DEBUG
            // 外观回归入口：`defaults write com.cogniterm.app demoTranscriptOnLaunch -bool YES`
            // 只往对话区落一段示例消息，不连 agent、不发请求。用于截图核对
            // Markdown 排版与代码块动作条——**真机外观没法用单测断言**，
            // 而 UI 自动化在这台机器上被 TCC 挡死（osascript -10004）。
            //
            // 用 UserDefaults 而不是启动参数：`open --args` 在本机实测传不进去
            // （`pgrep -f -- --flag` 命中不到，2026-10-26）。
            if UserDefaults.standard.bool(forKey: "demoTranscriptOnLaunch") {
                conversation.appendUser("终端会话切换能不能不用鼠标？")
                conversation.appendAssistant(Self.demoTranscript)
            }

            // 审批卡抓手：`defaults write com.cogniterm.app demoApprovalOnLaunch -bool YES`
            // 演示对端的第一条 prompt 必定回 tool_call(`rm -rf build/`) +
            // request_permission，于是启动就能截到「agent 想跑命令，等你批准」这一屏。
            if UserDefaults.standard.bool(forKey: "demoApprovalOnLaunch") {
                await sidecar.enterDemo()
                if let sid = sidecar.sessionID {
                    let text = "清一下构建产物"
                    conversation.appendUser(text)
                    conversation.setWorking(true)
                    do {
                        if let result = try await sidecar.client?.prompt(sessionId: sid, text: text) {
                            conversation.handlePromptResult(result)
                        } else {
                            conversation.setWorking(false)
                        }
                    } catch {
                        conversation.appendSystem("prompt 失败：\(error)")
                        conversation.setWorking(false)
                    }
                }
            }

            // 远程执行目录抓手：`defaults write com.cogniterm.app demoSSHPort -int 65021`
            // + `defaults write com.cogniterm.app demoSSHRemoteDirectory -string "/opt/app"`
            // 直接开一个指向本机高位端口的 SSH 会话（连接必然被拒），用来核对
            // 「远程会话的工具条长什么样、远程目录入口在不在」——UI 自动化被 TCC
            // 挡死（osascript -10004），这是唯一能自动截到这一屏的办法。
            if let demoPort = UserDefaults.standard.object(forKey: "demoSSHPort") as? Int {
                let remote = UserDefaults.standard.string(forKey: "demoSSHRemoteDirectory")
                sessions.openSSHSession(
                    target: SSHTarget(host: "127.0.0.1", port: demoPort, username: "demo"),
                    label: "demo@127.0.0.1",
                    root: FileManager.default.homeDirectoryForCurrentUser,
                    remoteDirectory: remote
                )
            }

            // 设置窗口抓手：`defaults write com.cogniterm.app demoSettingsOnLaunch -bool YES`
            // Settings 是独立 Scene，除了 ⌘, 没有程序化入口，而 UI 自动化在本机被
            // TCC 挡死（osascript -10004）。改文案后要靠这一屏核对行高与换行。
            //
            // 先试 selector（拿真窗口 → 看得到真实的 480×460 换行），没起来再退回
            // sheet：夹具不能有"有时不出图"这种不确定性。
            if UserDefaults.standard.bool(forKey: "demoSettingsOnLaunch") {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                NSApp.activate(ignoringOtherApps: true)
                Self.showSettingsWindow()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if !Self.settingsWindowIsVisible() { demoSettingsSheet = true }
            }

            // 新建 SSH 表单抓手：`defaults write com.cogniterm.app demoNewSSHOnLaunch -bool YES`
            // 表单只在 ⇧⌘N 之后才存在，同理需要一个不靠键盘的开法。
            if UserDefaults.standard.bool(forKey: "demoNewSSHOnLaunch") {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                showNewSSHSession = true
            }

            // 宠物抓手：`defaults write com.cogniterm.app demoPetLine -string "git st"`
            // 喂一行文本进去，等价于「用户刚敲完这行」——宠物面板与行内灰字都是
            // 输入驱动的，不这样喂就得真敲键盘（TCC 挡死，见 TerminalSession.injectDemoInput）。
            if let demoLine = UserDefaults.standard.string(forKey: "demoPetLine"), !demoLine.isEmpty {
                // 等 PTY 起来：scheduleLaunch 是异步的，早喂会写进 nil pty。
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                sessions.activeSession.injectDemoInput(demoLine)
            }
            #endif
        }
        // D1：终端里 cd 之后（OSC 7），审批卡与规则匹配的 cwd 跟着真实目录走。
        // 只同步 conversation.workspaceRoot——sidecar 的 workspaceRoot 是会话级
        // cwd，归 applyWorkspace 管，两个概念故意不合并。
        .onChange(of: terminal.shellDirectory) { _, newValue in
            if let newValue, newValue != conversation.workspaceRoot {
                conversation.workspaceRoot = newValue
            }
        }
        .sheet(isPresented: $sidecar.needsOnboarding) {
            OnboardingView(sidecar: sidecar)
        }
        .sheet(isPresented: $showNewSSHSession) {
            NewSSHSessionSheet()
        }
        #if DEBUG
        // 兜底夹具：与 Settings 场景同一个视图、同样的 480×460，只是换了容器。
        // 只用于核对文案换行，不代表真窗口的标题栏。
        .sheet(isPresented: $demoSettingsSheet) {
            SettingsView(sidecar: sidecar)
                .frame(width: 480, height: 460)
        }
        #endif
        // ⇧⌘N：菜单在视图树之外，只能靠计数变化把 sheet 拉起来。
        .onChange(of: appCommands.newSSHSessionRequests) { _, _ in
            showNewSSHSession = true
        }
        .sheet(item: $replay) { item in
            SessionReplayView(state: item.state, title: item.title)
        }
    }

    // MARK: - Sidebar

    /// 侧栏只有三段（上下文 / 会话 / 底栏），实现见 `SidebarView`。
    ///
    /// 2026-10-18 重排后的分工：
    /// - 终端会话与 SSH 书签 → 搬到终端面板的标签栏（`TerminalTabBar`）
    /// - serverInfo / 审批模式 / 沙箱 → 收进上下文弹层
    /// - 演示模式 / JSONL 回放 / 诊断 → 收进底栏「进阶」弹层
    /// - 会话配置（模型 / 推理档）→ 底栏一键切换
    /// - 历史会话 → 进侧栏即拉取、只露最近 5 条，全量进可搜索的 sheet
    private var sidebar: some View {
        SidebarView(
            sidecar: sidecar,
            conversation: conversation,
            terminalMCP: terminalMCP,
            workspacePath: $workspacePath,
            showDiagnostics: $showDiagnostics,
            onApplyWorkspace: applyWorkspace,
            onChooseWorkspace: chooseWorkspace,
            onReplayJSONL: chooseAndReplayJSONL
        )
    }

    // MARK: - Detail

    private var detail: some View {
        // 先量一次可用高度：终端该多高取决于「还剩多少地方」，不是常数。
        // 放在 detail 最外层而不是各个子视图里，是为了让拖拽手柄和 frame 用**同一个**
        // 数值——两处各测一次，在窗口缩放动画的那几帧里会算出不同的高度。
        GeometryReader { proxy in
            detailContent(availableHeight: proxy.size.height)
        }
    }

    private func detailContent(availableHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                cwdDivergenceBar
                TrajectoryView(conversation: conversation,
                               onRunCommand: runCommandFromMessage)
                if let pending = conversation.pendingTerminalCommand {
                    TerminalCommandCard(
                        pending: pending,
                        onAllow: { conversation.respondTerminalCommand(allow: true) },
                        onReject: { conversation.respondTerminalCommand(allow: false) }
                    )
                }
                if let pending = conversation.pendingPermission {
                    ApprovalCardView(
                        pending: pending,
                        workspaceRoot: conversation.workspaceRoot,
                        onRespond: { conversation.respond($0) },
                        onRemember: rememberRule,
                        // 「在终端运行」：respond reject（dsh 不执行）+ 命令注入
                        // 我们的 PTY + 输出捕获回喂。见 respondRunInTerminal。
                        onRunInTerminal: { command in
                            conversation.respondRunInTerminal()
                            pendingTerminalCommand = command
                            // 与 MCP 的 run_in_terminal 同一条路径：注入**活跃会话**
                            // （本地或 SSH 一致）。写死本地单例的话，用户在 SSH
                            // 会话里点「在终端运行」，命令会跑到看不见的本地终端里。
                            sessions.runCommandCaptured(command) { output in
                                feedTerminalOutputBackToAgent(command: command, output: output)
                            }
                        }
                    )
                }
                Divider()
                ComposerView(sidecar: sidecar, conversation: conversation)
            }
            // 与 `TerminalPanelSizing.conversationFloor` 是同一个数：
            // 那边按它算终端的封顶预算，这边按它约束实际布局。
            // 写成两处字面量的话，改一个忘一个 → 预算比实际大，两者互相挤。
            .frame(minHeight: TerminalPanelSizing.conversationFloor)
            .frame(maxHeight: .infinity)

            if terminalPanelCollapsed {
                collapsedTerminalBar
            } else {
                terminalResizeHandle(availableHeight: availableHeight)

                VStack(spacing: 0) {
                    // 会话切换在终端面板顶上（而不是侧栏）：用户看的是这块终端，
                    // 切会话的手应该落在这里。侧栏从此不再提「终端」。
                    TerminalTabBar(
                        sessions: sessions,
                        onNewSSH: { showNewSSHSession = true },
                        onError: { conversation.appendSystem($0) }
                    )
                    Divider()

                    // 每个会话一个常驻面板（ZStack + opacity）：切换会话不重建 NSView，
                    // 各会话的 scrollback、正在跑的命令、未读计数全部保留。
                    // 隐藏者不接收点击/键盘（allowsHitTesting），焦点由 SessionManager 交还。
                    ZStack {
                        ForEach(sessions.sessions) { session in
                            let isActive = session.id == sessions.activeSessionID
                            TerminalPanel(session: session, onRunCapture: { output in
                                guard let command = pendingTerminalCommand else { return }
                                feedTerminalOutputBackToAgent(command: command, output: output)
                            })
                            .opacity(isActive ? 1 : 0)
                            .allowsHitTesting(isActive)
                        }
                    }
                }
                // 标签栏算在终端面板高度里（可拖拽的仍是这一整块），
                // 否则每次展开都凭空多出 26pt 挤掉对话区。
                .frame(height: resolvedTerminalHeight(availableHeight: availableHeight))
            }
        }
    }

    /// 面板最终高度。
    ///
    /// 用户拖过就用他定的值，否则按行数下限 / 窗口比例自适应。**两种都要过一遍
    /// 当前窗口的预算**——窗口一缩就把对话区挤没、把终端留在原来的高度上，是
    /// 这种「记住绝对高度」的布局最容易出的问题。
    private func resolvedTerminalHeight(availableHeight: CGFloat) -> Double {
        let fontSize = sessions.activeSession.fontSize
        if customTerminalHeight > 0 {
            return TerminalPanelSizing.displayHeight(desired: customTerminalHeight,
                                                     available: availableHeight,
                                                     fontSize: fontSize)
        }
        return TerminalPanelSizing.idealHeight(available: availableHeight, fontSize: fontSize)
    }

    /// 终端目录 ≠ agent 工作区时的提示条。
    ///
    /// 双轨的成因是**协议级**的：dsh-acp 的 session cwd 在 session/new 时固定
    /// （`dsh-acp/lib/index.js:1217`，resume 还校验一致、不一致直接 invalidParams），
    /// 没有 session 级 cwd 变更 API。终端里 cd 到别处后 agent 的读写边界不会
    /// 跟着走——旧实现里这个 diverge 完全不可见，用户以为 agent「看到的是同一个
    /// 目录」，权限答案和文件列表全都对不上。
    /// 这里只做「可见 + 一键把终端拉回工作区」；反向（agent 跟随终端）需要重建
    /// 会话，归工作区切换流程管。
    private var cwdDivergenceBar: some View {
        Group {
            // 跟着**活跃**会话走，且只在本地会话显示。
            //
            // SSH 会话下这条**必须**关掉，理由不只是"无可比性"：远端 shell 若
            // 真的发了 OSC 7，`shellDirectory` 就是一个远程路径，拿它跟本地
            // workspacePath 比会得出"终端在 /opt/app，agent 工作区是 ~/CogniTerm"
            // 这种错乱提示，而旁边的「终端 cd 到工作区」按钮会把一个**本地**
            // 路径 `cd` 到远端去。
            //
            // 远程会话里「命令在哪跑」由终端工具栏的目录入口承载（唯一一处），
            // 「文件工具看的还是本地」由审批卡说明——不在这里再重复一遍。
            if sessions.activeSession.kind == .local,
               let shellDirectory = sessions.activeSession.shellDirectory,
               !workspacePath.isEmpty,
               shellDirectory != workspacePath {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                    Text("终端在 \(URL(fileURLWithPath: shellDirectory).lastPathComponent)，agent 工作区是 \(URL(fileURLWithPath: workspacePath).lastPathComponent)（agent 读写边界不跟随终端 cd）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button("终端 cd 到工作区") {
                        sessions.activeSession.syncWorkingDirectory()
                    }
                    .font(.caption2)
                    .disabled(!sessions.activeSession.status.isRunning)
                    .help("往终端注入 cd 命令，把 shell 拉回 agent 工作区")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.10))
            }
        }
    }

    /// 折叠后的终端条：24pt 横条 = 展开按钮 + 当前会话（可换）+ 目录。
    ///
    /// 折叠时标签栏看不到，所以这里补一个会话菜单——否则「有两条 SSH、其中一条
    /// 在跑构建」的情况下，折叠状态下无法切会话，只能先展开再切。
    private var collapsedTerminalBar: some View {
        HStack(spacing: 8) {
            Button {
                terminalPanelCollapsed = false
            } label: {
                Label("展开终端", systemImage: "chevron.up")
            }
            .font(.caption)
            .buttonStyle(.plain)
            .help("展开终端面板（⌘J 或双击原分隔条位置）")

            Menu {
                ForEach(sessions.sessions) { session in
                    Button {
                        sessions.activate(session.id)
                    } label: {
                        if session.id == sessions.activeSessionID {
                            Label(session.label, systemImage: "checkmark")
                        } else {
                            Text(session.label)
                        }
                    }
                }
            } label: {
                Text(sessions.activeSession.terminalTitle.isEmpty
                     ? sessions.activeSession.defaultTitle
                     : sessions.activeSession.terminalTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer(minLength: 8)
            if let directory = sessions.activeSession.directoryText {
                Text(directory)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// 终端与对话区之间的可拖拽分隔条。
    ///
    /// 为什么不用 VSplitView 的默认分隔：它的比例既不可读也不可写——
    /// 无法持久化、无法 clamp、拖动时也没有视觉反馈。4pt 自绘手柄 +
    /// 拖拽改 @AppStorage 里的高度，行为完全可控（单测 clamp 纯函数）。
    /// 双击 = 折叠/展开（⌘J 同款）：只想聊天时一下让出 220pt。
    private func terminalResizeHandle(availableHeight: CGFloat) -> some View {
        Rectangle()
            .fill(isDraggingHeight ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: TerminalPanelSizing.handleHeight)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel("调整终端面板高度")
            .help(resizeHandleHelp(availableHeight: availableHeight))
            .onTapGesture(count: 2) {
                terminalPanelCollapsed.toggle()
            }
            // 恢复自适应用右键而不是再抢一个双击：双击已经给了「折叠」，
            // 同一个手势背两种语义，用户只能靠猜。
            .contextMenu {
                Button("恢复自适应高度") { customTerminalHeight = 0 }
                    .disabled(customTerminalHeight <= 0)
                Divider()
                Button(terminalPanelCollapsed ? "展开终端" : "折叠终端") {
                    terminalPanelCollapsed.toggle()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDraggingHeight {
                            isDraggingHeight = true
                            // 从**现在看到的高度**起拖。自适应态下 customTerminalHeight
                            // 是 0，拿它当起点会让第一次拖拽直接跳到底。
                            heightAtDragStart = resolvedTerminalHeight(availableHeight: availableHeight)
                        }
                        // 存宽松钳制后的值，不存显示值：窗口拖小一次就永久变矮的 bug
                        // 就是这么来的，见 `clampedCustomHeight`。
                        customTerminalHeight = TerminalPanelSizing.clampedCustomHeight(
                            heightAtDragStart - value.translation.height
                        )
                    }
                    .onEnded { _ in isDraggingHeight = false }
            )
    }

    /// 拖柄的提示：把「现在能看多少行」直接写出来。
    ///
    /// 用户抱怨的从来不是"面板 xx pt 太矮"，而是"看不到两行输出"。把行数摆出来，
    /// 就不必再靠猜这个手柄该往上拖多少。
    private func resizeHandleHelp(availableHeight: CGFloat) -> String {
        let height = resolvedTerminalHeight(availableHeight: availableHeight)
        let rows = Int(TerminalPanelSizing.visibleRows(
            height: height,
            fontSize: sessions.activeSession.fontSize
        ))
        let mode = customTerminalHeight > 0 ? "固定高度" : "自适应"
        return "拖动调整高度（当前 \(Int(height))pt ≈ \(rows) 行，\(mode)）"
             + " · 双击折叠/展开（⌘J） · 右键恢复自适应"
    }

    #if DEBUG
    /// 打开设置窗口。
    ///
    /// Settings 是独立 Scene，SwiftUI 没给程序化入口；可用的 selector 名随系统版本变过
    /// （macOS 14 起 `showSettingsWindow:`，更早叫 `showPreferencesWindow:`），
    /// 所以两个都试一遍，命中即返回。
    static func showSettingsWindow() {
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector(name), to: nil, from: nil) { return }
        }
    }

    /// 设置窗口是不是真的起来了（selector 命中但窗口被吞掉时也要能察觉）。
    static func settingsWindowIsVisible() -> Bool {
        NSApp.windows.contains { win in
            guard win.isVisible, !(win is NSPanel) else { return false }
            let title = win.title
            return title.contains("Settings") || title.contains("设置")
        }
    }

    /// `--demo-transcript` 用的示例回复：覆盖标题 / 段落 / 有序列表 /
    /// 单行代码块（带「运行」）/ 多行代码块（只有复制与插入）/ 行内 code /
    /// 路径 / URL。改排版时先看这一屏。
    static let demoTranscript = """
    ### 结论

    切换成本都在**鼠标**上：`TerminalTabBar.swift` 里只有 `onTapGesture`。

    ### 改法

    1. 菜单加 ⌘1…⌘9，落到 `sessions.activateTab(at:)`
    2. ⇧⌘[ / ⇧⌘] 循环切换
    3. ⌘W 只关 SSH 标签

    ```bash
    git status --short
    ```

    ```swift
    Button("标签 1") { sessions.activateTab(at: 0) }
    ```

    SwiftTerm 只在**带 ⌘ 的键**上问宿主菜单（`MacTerminalView.swift:2055`），
    所以 ⌃Tab 走不通，见 https://github.com/Gcsimple/cogniterm 。
    """
    #endif

    /// 对话里代码块「运行」的落点。
    ///
    /// 与审批卡「在终端运行」共用同一条路径：注入**活跃会话**（本地或 SSH），
    /// 拿到收敛后的输出再回喂 agent。区别只在前置校验——代码块的「运行」
    /// 在视图层已经过 `RiskEvaluator`，高风险命令还会展开一次确认条，
    /// 所以这里不再弹审批卡（否则同一个决定要确认两遍）。
    private func runCommandFromMessage(_ command: String) {
        sessions.runCommandCaptured(command) { output in
            self.feedTerminalOutputBackToAgent(command: command, output: output)
        }
    }

    /// 「在终端运行」/ MCP 迟到输出收敛后，把终端输出作为新的 prompt 回喂给 agent。
    ///
    /// 语义上这是一条**新的用户消息**（不是工具结果）——两条来路：
    ///   ① 审批卡「在终端运行」：dsh 那边已 reject 工具调用，agent 需要从
    ///      「用户提供了命令的真实输出」这个事实继续；
    ///   ② MCP run_in_terminal 超过 55s 窗口才收敛：agent 已收到"仍在执行"
    ///      提示，这里补送完整输出。
    /// 措辞保持中立（不强调"没有让你直接执行"），两条路都说得通。
    private func feedTerminalOutputBackToAgent(command: String, output: String) {
        guard let sessionID = sidecar.sessionID, case .ready = sidecar.status else {
            conversation.appendSystem("sidecar 未就绪，终端输出未回喂（命令已在终端执行）")
            return
        }
        let prompt = """
        以下命令已在你的终端里执行完毕：
        `\(command)`
        终端实际输出：
        ```
        \(output)
        ```
        请基于以上输出继续。
        """
        conversation.appendSystem("正在把终端输出回喂给 agent…")
        conversation.setWorking(true)
        Task {
            do {
                let result = try await sidecar.client?.prompt(sessionId: sessionID, text: prompt)
                if let result {
                    conversation.handlePromptResult(result)
                } else {
                    conversation.setWorking(false)
                }
            } catch {
                conversation.appendSystem("回喂失败：\(error)")
                conversation.setWorking(false)
            }
        }
    }

    // MARK: - 操作

    private func applyWorkspace() {
        let standardized = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        workspacePath = standardized
        sidecar.workspaceRoot = URL(fileURLWithPath: standardized)
        conversation.workspaceRoot = standardized
        // 不再重启 shell：切工作区不该把正在跑的构建/ssh 一起干掉。
        // 终端只记住新目录，由工具条上的"同步目录"按钮决定何时注入 cd。
        terminal.workspaceChanged(to: URL(fileURLWithPath: standardized))
        // 已连接时切换工作区需要用新 cwd 重建会话。
        if case .ready = sidecar.status {
            Task {
                await sidecar.stop()
                await sidecar.start()
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            applyWorkspace()
        }
    }

    /// 选择 dsh 会话 JSONL → SessionReducer 归约 → 弹窗回放（富内容真相源仍是 JSONL）。
    private func chooseAndReplayJSONL() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "选择 dsh 会话 JSONL 轨迹"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let events = try JSONLFile.readAll(at: url)
            let state = SessionReducer.reduceAll(events: events)
            let kinds = Dictionary(grouping: events.map(\.kind), by: { $0 })
                .map { "\($0.key ?? "unknown"):\($0.value.count)" }
                .sorted()
                .joined(separator: "，")
            conversation.appendSystem("JSONL 读取成功：\(events.count) 条事件（\(kinds)）")
            replay = ReplayItem(state: state, title: url.lastPathComponent)
        } catch {
            conversation.appendSystem("JSONL 读取失败：\(error)")
        }
    }

    private func loadRules() {
        let descriptor = FetchDescriptor<ApprovalRuleRecord>()
        let records = (try? modelContext.fetch(descriptor)) ?? []
        conversation.ruleSet = RuleSet(rules: records.map(\.asPolicyRule))
    }

    /// 设置（审批模式 / 沙箱 / 遥测 / 默认模型）从 SwiftData 加载并应用到 sidecar 与审批桥。
    private func loadSettings() {
        let stored = (try? modelContext.fetch(FetchDescriptor<AppSettings>()))?.first
        let settings = SidecarService.Settings(
            policyMode: stored?.policyMode ?? .strict,
            sandboxMode: stored?.sandboxMode ?? .workspaceWrite,
            telemetryEnabled: stored?.telemetryEnabled ?? false,
            // 漏传会让 settings.defaultModel 恒为默认档，DSH_COGNITERM_PROVIDER /
            // DSH_COGNITERM_MODEL 与设置页里选的值不一致——而 sidecar 每次 start
            // 都读它，静默用错模型（或指向不存在的 provider 导致会话起不来）。
            defaultModel: stored?.modelSelection ?? .deepSeekDefault
        )
        sidecar.update(settings: settings)
    }

    private func rememberRule(_ rule: PolicyEngine.ApprovalRule) {
        modelContext.insert(ApprovalRuleRecord(rule))
        try? modelContext.save()
        loadRules()
    }
}
