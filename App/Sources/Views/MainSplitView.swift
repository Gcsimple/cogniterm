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
    /// SSH 书签（侧栏「SSH 书签」节的数据源）。
    @Query(sort: \SSHBookmark.lastUsedAt, order: .reverse) private var sshBookmarks: [SSHBookmark]
    /// 新建 SSH 会话表单。
    @State private var showNewSSHSession = false
    /// 终端 MCP server（agent 的 run_in_terminal 执行平面）。观察它是为了让
    /// 侧栏那行端点状态在监听成功/失败时自动刷新。
    @ObservedObject private var terminalMCP = TerminalMCPServer.shared

    @Environment(\.modelContext) private var modelContext
    /// 工作区路径。**持久化**（旧实现是 @State：用户选的工作区每次重启都丢，
    /// 静默重置回 $HOME，而 agent 的 glob 扫整个 home 必炸——TCC EPERM +
    /// 30s 超时，2026-10-17 用 5 个失败会话实证）。空串 = 首启，.task 里落默认值。
    @AppStorage("workspacePath") private var workspacePath: String = ""
    @State private var showDiagnostics = false
    @State private var history: [SessionInfo] = []
    @State private var historyLoading = false
    @State private var replay: ReplayItem?
    /// 终端面板高度（可拖拽分隔条调整）。@AppStorage 落盘，重启后保持。
    @AppStorage("terminalPanelHeight") private var terminalHeight: Double = 220
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
        .sheet(item: $replay) { item in
            SessionReplayView(state: item.state, title: item.title)
        }
    }

    // MARK: - Sidebar

    /// 侧栏信息架构（2026-10-17 重排）。
    ///
    /// 旧排法把「连接状态 / 演示模式 / 模型选择 / 工作区 / 历史 / JSONL / 诊断」
    /// 六组控制堆在一个 List 里，侧栏是控制面板而不是导航——用户进来第一眼是
    /// 一台机器状态屏，找不到「开始聊天」在哪。新排法按主任务排序：
    ///   会话（新会话）→ 工作区 → 历史会话 → 会话配置 → 连接 → 高级
    private var sidebar: some View {
        List {
            Section("会话") {
                Button {
                    Task { await sidecar.newSession() }
                } label: {
                    Label("新会话", systemImage: "plus.bubble")
                }
                .disabled(sidecar.sessionID == nil)
                .help(sidecar.sessionID == nil
                      ? "连接 sidecar 后才能创建会话"
                      : "忘掉当前上下文，在同一连接上重开一个会话（不断线）")

                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(sidecar.status.label)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if case .failed = sidecar.status {
                        Button {
                            applyWorkspace()
                            Task { await sidecar.bootstrap() }
                        } label: {
                            Label("重新连接", systemImage: "arrow.clockwise")
                        }
                        .font(.caption)
                    }
                }
                Text(sidecar.serverInfo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("审批模式：\(policyLabel) · 沙箱：\(sandboxLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("终端") {
                ForEach(sessions.sessions) { session in
                    terminalSessionRow(session)
                }
                Button {
                    showNewSSHSession = true
                } label: {
                    Label("新建 SSH 会话…", systemImage: "network")
                }
                .font(.caption)
            }

            if !sshBookmarks.isEmpty {
                Section("SSH 书签") {
                    ForEach(sshBookmarks) { bookmark in
                        Button {
                            openBookmark(bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bookmark.name)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(bookmarkSubtitle(bookmark))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("删除书签", role: .destructive) {
                                modelContext.delete(bookmark)
                                try? modelContext.save()
                            }
                        }
                    }
                }
            }

            Section("工作区") {
                TextField("绝对路径", text: $workspacePath)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit(applyWorkspace)
                Button("选择文件夹…") { chooseWorkspace() }
                    .font(.caption)
                Text("agent 的文件读写以这里为边界；切换会重建 agent 会话（历史会话可从下方恢复）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("历史会话") {
                Button {
                    Task { await refreshHistory() }
                } label: {
                    Label("刷新（session/list）", systemImage: "clock.arrow.circlepath")
                }
                .font(.caption)
                .disabled(sidecar.sessionID == nil || historyLoading)

                if historyLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("读取中…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                ForEach(history) { info in
                    Button {
                        Task { await sidecar.resumeSession(info) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.title ?? info.sessionId)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(info.cwd ?? "—") · \(info.updatedAt ?? "")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("会话配置") {
                if sidecar.configOptions.isEmpty {
                    Text(sidecar.sessionID == nil ? "连接后显示" : "服务端未广告可配置项")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(orderedConfigOptions, id: \.id) { option in
                        SessionConfigPicker(option: option) { value in
                            Task { await sidecar.setConfigOption(id: option.id, value: value) }
                        }
                    }
                    Text("经 ACP session/set_config_option 实时生效（后续轮次），不需要重连。"
                         + "设置页的「默认模型」是启动缺省值，二者互不覆盖。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("连接") {
                switch sidecar.status {
                case .needsKey:
                    Button {
                        sidecar.needsOnboarding = true
                    } label: {
                        Label("设置 API Key…", systemImage: "key")
                    }
                case .starting, .ready:
                    Button(role: .destructive) {
                        Task { await sidecar.stop() }
                    } label: {
                        Label("断开", systemImage: "stop.circle")
                    }
                    .disabled(sidecar.status == .starting)
                case .failed, .stopped:
                    Button {
                        applyWorkspace()
                        Task { await sidecar.bootstrap() }
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                }
                Button {
                    applyWorkspace()
                    Task { await sidecar.enterDemo() }
                } label: {
                    Label("演示模式", systemImage: "wand.and.stars")
                }
                .font(.caption)
                .disabled(isBusy)
                .help("无 API Key 也能走完整 UI/协议链路（LoopbackTransport + DemoPeer）")

                Text("终端工具（agent run_in_terminal）：\(terminalMCP.endpointDescription)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Section("JSONL 轨迹") {
                Button("选择 JSONL 并回放会话…") { chooseAndReplayJSONL() }
                    .font(.caption)
            }

            Section {
                Toggle("诊断输出", isOn: $showDiagnostics)
                if showDiagnostics {
                    ScrollView {
                        Text(sidecar.diagnostics.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                }
            } header: {
                Text("诊断")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - 终端会话 / 书签

    /// 侧栏一行会话：状态点 + 名称 + 运行态；点击切换，右键关闭（仅 SSH）。
    ///
    /// 渲染交给 `TerminalSessionRow`：它会各自 `@ObservedObject` 订阅自己那条会话。
    /// 直接在方法里读 `session.status` 只有**活跃**会话能刷新（SessionManager 只转发
    /// 活跃会话的变化），后台正在连的 SSH 会一直显示旧状态点。
    private func terminalSessionRow(_ session: TerminalSession) -> some View {
        TerminalSessionRow(
            session: session,
            isActive: session.id == sessions.activeSessionID,
            onActivate: { sessions.activate(session.id) },
            onClose: { sessions.close(session.id) },
            onRestart: { session.restart() }
        )
    }

    private func bookmarkSubtitle(_ bookmark: SSHBookmark) -> String {
        var parts: [String] = []
        if !bookmark.username.isEmpty { parts.append(bookmark.username) }
        parts.append(bookmark.port == 22 ? bookmark.host : "\(bookmark.host):\(bookmark.port)")
        if let jump = bookmark.jumpHost, !jump.isEmpty { parts.append("经 \(jump)") }
        return parts.joined(separator: " @ ")
    }

    private func target(from bookmark: SSHBookmark) -> SSHTarget {
        SSHTarget(
            host: bookmark.host,
            port: bookmark.port,
            username: bookmark.username.isEmpty ? nil : bookmark.username,
            identityFilePath: bookmark.identityFilePath,
            jumpHost: bookmark.jumpHost
        )
    }

    private func openBookmark(_ bookmark: SSHBookmark) {
        let target = target(from: bookmark)
        guard target.isValid else {
            sidecar.diagnostics.append("[ssh] 书签「\(bookmark.name)」参数不合法，已忽略")
            return
        }
        bookmark.lastUsedAt = Date()
        try? modelContext.save()
        sessions.openSSHSession(
            target: target,
            label: bookmark.name,
            root: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    // MARK: - Detail

    private var detail: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                cwdDivergenceBar
                TrajectoryView(conversation: conversation)
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
            .frame(minHeight: 320)
            .frame(maxHeight: .infinity)

            if terminalPanelCollapsed {
                collapsedTerminalBar
            } else {
                terminalResizeHandle

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
                .frame(height: terminalHeight)
            }
        }
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
            // 跟着**活跃**会话走：切到 SSH 时 shellDirectory 恒为 nil（远端 cwd
            // 与本地工作区无可比性），提示条自然隐藏，不会拿本地的旧目录骗人。
            if let shellDirectory = sessions.activeSession.shellDirectory,
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

    /// 折叠后的终端条：24pt 横条 = 展开按钮 + 标题。双击分隔条或 ⌘J 也可展开。
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
            Text(sessions.activeSession.terminalTitle.isEmpty
                 ? sessions.activeSession.defaultTitle
                 : sessions.activeSession.terminalTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
    private var terminalResizeHandle: some View {
        Rectangle()
            .fill(isDraggingHeight ? Color.accentColor : Color(nsColor: .separatorColor))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .accessibilityLabel("调整终端面板高度")
            .help("拖动调整高度 · 双击折叠/展开终端（⌘J）")
            .onTapGesture(count: 2) {
                terminalPanelCollapsed.toggle()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDraggingHeight {
                            isDraggingHeight = true
                            heightAtDragStart = terminalHeight
                        }
                        terminalHeight = Self.clampedTerminalHeight(
                            heightAtDragStart - value.translation.height
                        )
                    }
                    .onEnded { _ in isDraggingHeight = false }
            )
    }

    /// 终端高度钳制范围（pt）。下限保证工具栏 + 一行输出可见，
    /// 上限给对话区留够空间（窗口 minHeight 600 - 320 对话区 - chrome）。
    static func clampedTerminalHeight(_ value: Double) -> Double {
        min(max(value, 120), 480)
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

    private var isBusy: Bool {
        switch sidecar.status {
        case .starting, .ready: true
        default: false
        }
    }

    private var statusColor: Color {
        switch sidecar.status {
        case .ready: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        case .needsKey: return .yellow
        }
    }

    private var policyLabel: String {
        switch sidecar.settings.policyMode {
        case .strict: return "严格"
        case .rules: return "规则"
        case .closed: return "闭关"
        }
    }

    private var sandboxLabel: String {
        switch sidecar.settings.sandboxMode {
        case .readOnly: return "只读"
        case .workspaceWrite: return "工作区可写"
        case .off: return "关闭"
        }
    }

    /// 只保留 select 型（boolean 型 dsh 0.2 的 set 不接收，放上来只会必然失败）；
    /// 模型项提到最前，其余保持服务端顺序。
    private var orderedConfigOptions: [SessionConfigOption] {
        let selects = sidecar.configOptions.filter(\.isSelect)
        let models = selects.filter { $0.id == SessionConfigID.model || $0.category == "model" }
        return models + selects.filter { $0.id != SessionConfigID.model && $0.category != "model" }
    }

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

    private func refreshHistory() async {
        historyLoading = true
        defer { historyLoading = false }
        do {
            history = try await sidecar.listHistory()
            if history.isEmpty {
                conversation.appendSystem("当前工作区没有 dsh 历史会话")
            }
        } catch {
            conversation.appendSystem("读取历史会话失败：\(error)")
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
            // 漏传会让 settings.agentModel 恒为默认档，DSH_COGNITERM_MODEL 与设置页
            // 里选的值不一致——而 sidecar 每次 start 都读它，静默用错模型。
            agentModel: stored?.agentModel ?? .flash
        )
        sidecar.update(settings: settings)
    }

    private func rememberRule(_ rule: PolicyEngine.ApprovalRule) {
        modelContext.insert(ApprovalRuleRecord(rule))
        try? modelContext.save()
        loadRules()
    }
}

/// 侧栏的一行终端会话（本地 / SSH 同款渲染）。
///
/// 单独成 view 的唯一原因是**订阅粒度**：会话状态是各会话自己的 `@Published`，
/// 而 `SessionManager` 只转发活跃会话的 `objectWillChange`。写在外层方法里时，
/// 后台正在连接的 SSH 会话状态点不会更新（用户看到「从没连上过」的假象）。
private struct TerminalSessionRow: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onRestart: () -> Void

    /// 状态点的颜色语义：绿=跑着，橙=已退出（可重启），红=起不来，灰=空闲/未连。
    private var dotColor: Color {
        switch session.status {
        case .running: return .green
        case .exited: return .orange
        case .failed: return .red
        case .idle: return Color.secondary.opacity(0.35)
        }
    }

    var body: some View {
        Button(action: onActivate) {
            HStack(spacing: 8) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(session.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("重启", action: onRestart)
            // 本地会话不提供关闭：它是 agent 的默认执行平面（关掉后 run_in_terminal
            // 无处可去，而菜单/审批卡都默认它存在）。
            if session.kind == .ssh {
                Button("关闭会话", role: .destructive, action: onClose)
            }
        }
    }
}

/// 一个 select 型会话配置项的选择器。
///
/// 通用渲染而不是给模型写死 UI：dsh 广告的是「选项集」而不是「模型」，把
/// `model` / `reasoning_effort` 都按同一套渲染，将来上游加选项（或第三方 ACP
/// 对端加 `_` 前缀扩展）不用改这里。
///
/// 选择动作**不做乐观更新**：`onSelect` 只把值交给 sidecar 发请求，界面显示
/// 的永远是服务端最近一次返回的 `currentValue`。切失败就保持原值（fail-closed）。
private struct SessionConfigPicker: View {
    let option: SessionConfigOption
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker(option.label, selection: Binding(
                get: { option.currentSelectValue ?? "" },
                set: { newValue in
                    guard newValue != option.currentSelectValue else { return }
                    onSelect(newValue)
                }
            )) {
                // value 唯一（dsh 的 modelValue 是 provider+model 的 JSON 串），可直接当 id。
                ForEach(choices, id: \.value) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
            .font(.caption)

            if let description = option.description, !description.isEmpty {
                Text(description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private struct Choice {
        let value: String
        let label: String
    }

    private var choices: [Choice] {
        guard let options = option.selectOptions else { return [] }
        let groups = options.groups.filter { !$0.options.isEmpty }
        let multiGroup = groups.count > 1
        var result = groups.flatMap { group in
            group.options.map { item in
                Choice(value: item.value,
                       label: multiGroup && !group.label.isEmpty
                           ? "\(group.label) · \(item.label)" : item.label)
            }
        }
        // Picker 的 selection 必须能在 tags 里找到，否则显示空白。
        // 当前值不在选项集里时补一条——dsh 的 reasoning_effort 用空串表示
        // "服务端默认"，而那个空串不一定出现在选项列表里。
        if let current = option.currentSelectValue,
           !result.contains(where: { $0.value == current }) {
            result.insert(Choice(value: current,
                                 label: current.isEmpty ? "服务端默认" : current),
                          at: 0)
        }
        return result
    }
}
