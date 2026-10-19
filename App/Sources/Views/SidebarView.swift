import SwiftUI
import AppKit
import AcpClient
import Persistence
import SessionLogReader

/// 左侧栏：只有「上下文 / 会话 / 底栏」三段。
///
/// 2026-10-18 重排。旧版是 9 个 Section 平铺在一条垂直流里：导航动作、机器遥测
/// （serverInfo / 审批模式 / MCP 端点）、开发者工具（JSONL / 诊断）混在一起，
/// 用户进来第一眼是一台机器的状态屏；「重新连接」还同时出现在「会话」和「连接」
/// 两节里。重排的三条判据：
///
/// 1. **常驻 vs 滚动**：上下文头和底栏不滚，只有会话列表滚——低频信息不该把
///    高频列表挤出屏幕。
/// 2. **一个动作只有一处**：重连收进上下文弹层；终端相关全部移出侧栏（见
///    `TerminalTabBar`，会话属于终端面板而不是导航）。
/// 3. **默认可见优先**：历史会话进侧栏就自动拉取（旧实现要点「刷新」才看得见，
///    等于把「恢复上次会话」藏起来了），只露最近几条，全量进可搜索的 sheet。
struct SidebarView: View {
    @ObservedObject var sidecar: SidecarService
    @ObservedObject var conversation: ConversationModel
    @ObservedObject var terminalMCP: TerminalMCPServer
    @Binding var workspacePath: String
    @Binding var showDiagnostics: Bool

    /// 切换工作区（会重建 sidecar 会话，由 MainSplitView 统一处理）。
    var onApplyWorkspace: () -> Void
    var onChooseWorkspace: () -> Void
    var onReplayJSONL: () -> Void

    @State private var recent: [SessionSummary] = []
    @State private var previewTarget: SessionPreview?
    /// 正在解压/归约的会话 id（行上显示小转圈，避免点了没反馈）。
    @State private var previewLoading: String?
    @State private var previewError: String?
    @State private var showHistorySheet = false
    @State private var showContextDetails = false
    @State private var showAdvanced = false
    @State private var showSessionConfig = false
    /// 等待确认删除的会话。删除本身不可怕，可怕的是"点了就没了"——先问一句。
    @State private var pendingDelete: SessionSummary?

    /// 侧栏只露最近 N 条：历史会一直长，侧栏高度不能被它无限撑开。
    private static let recentLimit = 5

    var body: some View {
        VStack(spacing: 0) {
            contextHeader
            Divider()
            workspaceBar
            Divider()
            List {
                Section {
                    Button {
                        Task { await sidecar.newSession() }
                    } label: {
                        Label("新会话", systemImage: "plus.bubble")
                    }
                    .buttonStyle(.plain)
                    .disabled(sidecar.sessionID == nil)
                    .help(sidecar.sessionID == nil
                          ? "连接 sidecar 后才能创建会话"
                          : "忘掉当前上下文，在同一连接上重开一个会话（不断线）")
                }

                Section("当前") {
                    currentSessionRow
                }

                Section("最近会话") {
                    recentSection
                }
            }
            .listStyle(.sidebar)
            Divider()
            footer
        }
        // 本地索引是读盘，几十毫秒级：不再需要"加载中"状态机，进侧栏就刷。
        .task { reloadRecent() }
        // 新建 / 恢复 / 聊完一轮后 sessionID 会变：列表要跟着长出来，
        // 否则用户得重启 app 才能看到刚聊过的那条。
        .onChange(of: sidecar.sessionID) { _, _ in reloadRecent() }
        .onChange(of: sidecar.status) { _, _ in reloadRecent() }
        // 弹层里删过东西，关掉时侧栏要跟着更新（弹层自己只管它那份列表）。
        .onChange(of: showHistorySheet) { _, isOpen in
            if !isOpen { reloadRecent() }
        }
        .confirmationDialog(
            pendingDelete.map { "把「\($0.displayTitle)」移到废纸篓？" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("会话轨迹会进废纸篓，可以恢复；列表里不再显示这条。")
        }
        .sheet(isPresented: $showHistorySheet) {
            RecentSessionsSheet(sidecar: sidecar) { summary in
                // 全量列表里点一条，走的也是"先看再决定"的预览，不是直接 resume。
                openPreview(summary)
            }
        }
        .sheet(item: $previewTarget) { target in
            SessionPreviewSheet(sidecar: sidecar, target: target) {
                Task { await sidecar.resumeSession(target.summary) }
            }
        }
    }

    // MARK: - 上下文头

    /// 一行讲清「连上没有 / 用的哪个模型」，点开才是细节。
    ///
    /// 旧版把 serverInfo、审批模式、沙箱三行都常驻在「会话」节里，等于每次扫视
    /// 侧栏都要读一遍机器自检报告。
    private var contextHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Button {
                showContextDetails.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(shortStatus)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(modelSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showContextDetails, arrowEdge: .bottom) {
                contextDetails
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置（⌘,）：API Key、默认模型、审批与沙箱")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var contextDetails: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(sidecar.serverInfo)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("审批：\(policyLabel) · 沙箱：\(sandboxLabel)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            switch sidecar.status {
            case .needsKey:
                Button {
                    showContextDetails = false
                    sidecar.needsOnboarding = true
                } label: {
                    Label("设置 API Key…", systemImage: "key")
                }
            case .starting, .ready:
                Button(role: .destructive) {
                    showContextDetails = false
                    Task { await sidecar.stop() }
                } label: {
                    Label("断开连接", systemImage: "stop.circle")
                }
                .disabled(sidecar.status == .starting)
            case .failed, .stopped:
                Button {
                    showContextDetails = false
                    onApplyWorkspace()
                    Task { await sidecar.bootstrap() }
                } label: {
                    Label("重新连接", systemImage: "arrow.clockwise")
                }
            }

            Button {
                showContextDetails = false
                onApplyWorkspace()
                Task {
                    await sidecar.stop()
                    await sidecar.start()
                }
            } label: {
                Label("按当前工作区重建 sidecar", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(sidecar.status == .starting)
            .help("工作区是启动参数（WORKSPACE_ROOT + 内层沙箱 cwd），改完必须重建才生效")

            SettingsLink {
                Label("设置…", systemImage: "gearshape")
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: - 工作区

    /// 最高频的上下文变量，做成常驻条：点一下换目录，右键复制路径 / 去 Finder。
    ///
    /// 旧版是一个要手打绝对路径的 TextField——路径打错不会立刻报错，而是等 sidecar
    /// 启动时才失败；选目录本来就有 NSOpenPanel（自带 TCC 授权链）。
    private var workspaceBar: some View {
        Button {
            onChooseWorkspace()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(workspaceName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(workspacePath)
        .contextMenu {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: workspacePath)])
            }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(workspacePath, forType: .string)
            }
            Divider()
            Button("选择文件夹…") { onChooseWorkspace() }
            // 旧版的 TextField 会把手输的 `log` 当相对路径解析成 `~/log`，
            // 这类"被带偏"的工作区需要一条回到默认值的路（不擅自改用户数据）。
            Button("恢复默认工作区（~/CogniTerm）") {
                let fallback = SidecarService.defaultWorkspaceURL()
                try? FileManager.default.createDirectory(
                    at: fallback, withIntermediateDirectories: true)
                workspacePath = fallback.path
                onApplyWorkspace()
            }
        }
    }

    // MARK: - 当前会话

    /// 当前会话的「标题」取用户第一句话：dsh 不给标题，而 `sessionId` 对人无意义。
    private var currentSessionRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(currentTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 5) {
                if conversation.isWorking {
                    ProgressView().controlSize(.mini)
                }
                Text(currentSubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .contextMenu {
            // 会话 id 从正文挪到这里：需要它的人（报 bug、翻日志）拿得到，
            // 不需要的人不会被一串十六进制打扰。
            Button("复制会话 id") {
                guard let id = sidecar.sessionID else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(id, forType: .string)
            }
            .disabled(sidecar.sessionID == nil)
        }
    }

    private var currentTitle: String {
        guard let first = conversation.rows.first(where: { $0.kind == .user })?.text else {
            return "还没开始对话"
        }
        let line = first.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? first
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "还没开始对话" }
        return String(trimmed.prefix(60))
    }

    private var currentSubtitle: String {
        var parts: [String] = ["\(conversation.rows.count) 条记录"]
        if let usage = conversation.usage, usage.size > 0 {
            let percent = Int((Double(usage.used) / Double(usage.size) * 100).rounded())
            parts.append("上下文 \(percent)%")
        }
        // 这里**不再拼会话 id 前 8 位**。它是 UUID 片段，对人没有任何信息量，
        // 却占着副标题最显眼的位置——同一个毛病在「最近会话」里刚被用户点掉。
        // id 仍然可得：右键复制，或弹层里的 serverInfo。
        return parts.joined(separator: " · ")
    }

    // MARK: - 最近会话

    /// 侧栏的「最近会话」。
    ///
    /// 与旧版的三个差别（旧版被用户当场否掉："对 terminal 场景没用，UUID 索引不实用"）：
    ///   1. 标题来自 dsh 自己的 projcache（= 首条用户消息），不再显示 UUID 前缀；
    ///   2. 空会话（建了但没说过话，本机占 56%）默认不列；
    ///   3. 点一下**先看轨迹**再决定要不要在这个上下文里继续——因为
    ///      `session/resume` 不回放历史消息，直接 resume 等于恢复了一段看不见的对话。
    @ViewBuilder
    private var recentSection: some View {
        if let previewError {
            Text(previewError)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
        }

        if recent.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(emptyHistoryText)
                    .font(.caption)
                Text("空会话（没说过话的）不显示")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            ForEach(recent.prefix(Self.recentLimit)) { summary in
                Button {
                    openPreview(summary)
                } label: {
                    recentRow(summary)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("预览") { openPreview(summary) }
                    // 当前会话不在这里给删除入口：dsh 内存里还挂着它，删了目录只会在
                    // 下次 resume 时炸掉。要清就先用「新会话」把上下文换掉。
                    if summary.sessionId != sidecar.sessionID {
                        Button("移到废纸篓…", role: .destructive) { pendingDelete = summary }
                    }
                }
            }
            Button {
                showHistorySheet = true
            } label: {
                HStack(spacing: 4) {
                    Text("查看全部 \(recent.count) 条")
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }
                .font(.caption2)
            }
            .buttonStyle(.plain)
        }
    }

    private var emptyHistoryText: String {
        sidecar.status == .ready
            ? "这个工作区还没有对话"
            : "连接后显示这个工作区的对话"
    }

    /// 单行：左边标题（可读），右边相对时间。
    ///
    /// 不显示 UUID、也不显示 cwd：这些会话按定义都在当前工作区（跨工作区的会被
    /// 过滤掉，因为 resume 会校验 cwd），一列 `~/CogniTerm` 只占地方不提供信息。
    private func recentRow(_ summary: SessionSummary) -> some View {
        HStack(spacing: 6) {
            if previewLoading == summary.sessionId {
                ProgressView().controlSize(.small).scaleEffect(0.6)
            }
            Text(summary.displayTitle)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let when = Self.relativeTime(summary.lastActivity ?? summary.createdAt) {
                Text(when)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
    }

    /// 解压 + 归约后弹预览。失败只提示，不影响列表。
    private func openPreview(_ summary: SessionSummary) {
        previewError = nil
        previewLoading = summary.sessionId
        Task {
            defer { previewLoading = nil }
            do {
                let state = try await sidecar.replayState(for: summary)
                previewTarget = SessionPreview(summary: summary, state: state)
            } catch {
                previewError = "\(summary.displayTitle)：\(error.localizedDescription)"
            }
        }
    }

    /// 相对时间：7 天内用「3 小时前」，更早的用日期。永不返回 nil 之外的噪音。
    static func relativeTime(_ date: Date?) -> String? {
        guard let date else { return nil }
        let age = Date().timeIntervalSince(date)
        if age < 60 { return "刚刚" }
        if age > 7 * 24 * 3600 {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: date)
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// 读本地索引。同步、几十毫秒，所以不需要 loading 状态。
    private func reloadRecent() {
        recent = sidecar.recentSessions()
    }

    /// 确认后真正动手：移入废纸篓 + 刷新列表。失败只提示，不弹崩溃。
    private func confirmDelete() {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        do {
            try sidecar.deleteSession(target)
            if previewTarget?.summary.sessionId == target.sessionId { previewTarget = nil }
            previewError = nil
            reloadRecent()
        } catch {
            previewError = "删除失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 底栏

    /// 两条低频入口：左边「进阶」收开发者工具，右边「模型 · 审批」一键看当前状态。
    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showAdvanced.toggle()
            } label: {
                Label("进阶", systemImage: "slider.horizontal.3")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAdvanced, arrowEdge: .top) {
                advancedPanel
            }

            Spacer(minLength: 4)

            Button {
                showSessionConfig.toggle()
            } label: {
                Text("\(currentModelShort) · \(policyLabel)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSessionConfig, arrowEdge: .top) {
                sessionConfigPanel
            }
            .help("当前会话的模型 / 推理强度（实时生效）与审批模式")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showAdvanced = false
                onApplyWorkspace()
                Task { await sidecar.enterDemo() }
            } label: {
                Label("演示模式", systemImage: "wand.and.stars")
            }
            .disabled(isBusy)
            .help("无 API Key 也能走完整 UI/协议链路（LoopbackTransport + DemoPeer）")

            Button {
                showAdvanced = false
                onReplayJSONL()
            } label: {
                Label("回放 JSONL 轨迹…", systemImage: "doc.text.magnifyingglass")
            }

            Divider()

            Toggle("诊断输出", isOn: $showDiagnostics)

            if showDiagnostics {
                ScrollView {
                    Text(sidecar.diagnostics.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 160)
            }

            Text("终端工具 MCP：\(terminalMCP.endpointDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: showDiagnostics ? 420 : 280, alignment: .leading)
    }

    private var sessionConfigPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            Text("审批模式 \(policyLabel) · 沙箱 \(sandboxLabel)（在设置里改）")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }

    // MARK: - 文案与派生状态

    private var isBusy: Bool {
        switch sidecar.status {
        case .starting, .ready: return true
        default: return false
        }
    }

    /// 头一行只放状态本身：`failed` 的完整原因太长，塞进弹层。
    private var shortStatus: String {
        switch sidecar.status {
        case .stopped: return "未连接"
        case .starting: return "启动中…"
        case .ready: return "已连接"
        case .needsKey: return "需要 API Key"
        case .failed: return "连接失败"
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

    /// 当前模型：优先取服务端实时返回值（切过模型后这才是真相）。
    private var currentModelShort: String {
        if let label = sidecar.modelConfigOption?.currentLabel, !label.isEmpty {
            return label
        }
        // 未连接时回落显示配置里的默认模型。自定义端点的模型 id 不一定在内置
        // 枚举里，所以先按原始 id 显示，认不出来才走内置档的短名。
        let selection = sidecar.settings.defaultModel
        if let model = AgentModel(rawValue: selection.modelID), selection.isBuiltinDeepSeek {
            switch model {
            case .flash: return "Flash"
            case .pro: return "Pro"
            }
        }
        return selection.modelID
    }

    private var modelSummary: String {
        "模型 \(currentModelShort)"
    }

    /// 工作区在侧栏里只显示「名字」，但家目录要带 `~` 前缀：
    /// 只写 `log` 的话，用户分不清那是 `~/log` 还是某个项目里的子目录。
    private var workspaceName: String {
        if workspacePath.isEmpty { return "未设置工作区" }
        return abbreviateHome(workspacePath)
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
}

/// 一个 select 型会话配置项的选择器。
///
/// 通用渲染而不是给模型写死 UI：dsh 广告的是「选项集」而不是「模型」，把
/// `model` / `reasoning_effort` 都按同一套渲染，将来上游加选项（或第三方 ACP
/// 对端加 `_` 前缀扩展）不用改这里。
///
/// 选择动作**不做乐观更新**：`onSelect` 只把值交给 sidecar 发请求，界面显示
/// 的永远是服务端最近一次返回的 `currentValue`。切失败就保持原值（fail-closed）。
struct SessionConfigPicker: View {
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
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(option.label)
                .font(.caption2)
                .foregroundStyle(.secondary)

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

/// 家目录缩写成 `~`：侧栏只有 280pt，`/Users/xxx/log` 会把路径挤成 `…/log`，
/// 反而看不出这是家目录下的目录。
private func abbreviateHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

/// 会话预览：解压轨迹 → 归约 → 回放，然后才让用户决定要不要"在这个上下文里继续"。
struct SessionPreview: Identifiable {
    let summary: SessionSummary
    let state: SessionViewState
    var id: String { summary.sessionId }
}

struct SessionPreviewSheet: View {
    let sidecar: SidecarService
    let target: SessionPreview
    var onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SessionReplayView(state: target.state, title: target.summary.displayTitle)

            Divider()

            HStack(spacing: 10) {
                Text(metaLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("在此上下文继续") {
                    onContinue()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canContinue)
                .help(continueHint)
            }
            .padding(12)
        }
        .frame(width: 780, height: 620)
    }

    /// 能不能在这里继续。两个门槛：连接就绪（否则没人接单），以及**工作区一致**——
    /// dsh 的 `session/resume` 会校验 cwd，跨工作区的会话硬 resume 只会失败。
    private var canContinue: Bool {
        sidecar.status == .ready && sidecar.canResume(target.summary)
    }

    private var continueHint: String {
        if sidecar.status != .ready { return "sidecar 未连接时无法接续" }
        if !sidecar.canResume(target.summary) {
            return "这条会话属于另一个工作区（\(target.summary.cwd ?? "未知")），dsh 会拒绝 resume；可以看、可以复制、可以删"
        }
        return "接续这条会话继续聊（不会重放上面的内容）"
    }

    private var metaLine: String {
        var parts: [String] = []
        if let created = target.summary.createdAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append(formatter.string(from: created))
        }
        parts.append("\(target.summary.userMessageCount) 条你的消息")
        if let trajectory = target.summary.trajectory {
            parts.append(trajectory.deletingLastPathComponent().lastPathComponent)
        }
        return parts.joined(separator: " · ")
    }
}

/// 最近会话全量列表（侧栏只露最近几条，全量在这里搜）。
///
/// 单独一张表而不是侧栏内滚动：历史会无限增长，塞进侧栏要么撑爆高度要么变成
/// 一个又窄又长的嵌套滚动区，两边都不好用。
///
/// 数据源是**本地落盘索引**（projcache + 轨迹 mtime），不是 ACP 的 `session/list`：
/// 后者把标题和 createdAt 裁掉了，只剩 UUID。
struct RecentSessionsSheet: View {
    @ObservedObject var sidecar: SidecarService
    /// 选中一条 → 交给侧栏走"先看再决定"的预览流程。
    var onPick: (SessionSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionSummary] = []
    @State private var query = ""
    @State private var showBlank = false
    /// 默认只看当前工作区（那些才 resume 得动）；关掉是为了清理旧工作区留下的会话。
    @State private var onlyCurrentWorkspace = true
    @State private var pendingDelete: SessionSummary?
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("最近会话")
                    .font(.headline)
                Text("\(visible.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新扫描本地会话目录")
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            HStack(spacing: 10) {
                TextField("按标题或路径过滤", text: $query)
                    .textFieldStyle(.roundedBorder)
                Toggle("只看当前工作区", isOn: $onlyCurrentWorkspace)
                    .toggleStyle(.checkbox)
                Toggle("显示空会话", isOn: $showBlank)
                    .toggleStyle(.checkbox)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            if visible.isEmpty {
                Text(sessions.isEmpty ? "这个工作区还没有对话" : "没有匹配的会话")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { summary in
                    Button {
                        onPick(summary)
                        dismiss()
                    } label: {
                        row(summary)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("复制会话 id") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(summary.sessionId, forType: .string)
                        }
                        if let cwd = summary.cwd {
                            Button("复制工作区路径") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(cwd, forType: .string)
                            }
                        }
                        Divider()
                        if summary.sessionId == sidecar.sessionID {
                            Text("当前会话不能删")
                        } else {
                            Button("移到废纸篓…", role: .destructive) { pendingDelete = summary }
                        }
                    }
                }
                .listStyle(.inset)
            }

            if let deleteError {
                Text(deleteError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            Text("标题来自 dsh 本地写的首条用户消息；空会话默认隐藏。点一条先看轨迹，再决定要不要在该上下文继续——跨工作区的会话看得到、删得掉，但 resume 会被 dsh 拒绝。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 620, height: 520)
        .task { reload() }
        .onChange(of: showBlank) { _, _ in reload() }
        .onChange(of: onlyCurrentWorkspace) { _, _ in reload() }
        .confirmationDialog(
            pendingDelete.map { "把「\($0.displayTitle)」移到废纸篓？" } ?? "",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { confirmDelete() }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("会话轨迹会进废纸篓，可以恢复；列表里不再显示这条。")
        }
    }

    private func confirmDelete() {
        guard let target = pendingDelete else { return }
        pendingDelete = nil
        do {
            try sidecar.deleteSession(target)
            deleteError = nil
            reload()
        } catch {
            deleteError = "删除失败：\(error.localizedDescription)"
        }
    }

    private func row(_ summary: SessionSummary) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .foregroundStyle(summary.isBlank ? .secondary : .primary)
                Text(meta(summary))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if let when = SidebarView.relativeTime(summary.lastActivity ?? summary.createdAt) {
                Text(when)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func meta(_ summary: SessionSummary) -> String {
        var parts: [String] = []
        if summary.isBlank {
            parts.append("空会话")
        } else {
            parts.append("\(summary.userMessageCount) 条你的消息")
        }
        // 这份列表按定义只含当前工作区的会话（resume 会校验 cwd），所以每行都写一遍
        // `~/CogniTerm` 纯属噪音。只有跨工作区时才值得标出来（目前不会发生，留作兜底）。
        if let cwd = summary.cwd, !cwd.isEmpty,
           SidecarService.canonicalPath(cwd)
            != SidecarService.canonicalPath(sidecar.workspaceRoot.path) {
            parts.append(abbreviateHome(cwd))
        }
        return parts.joined(separator: " · ")
    }

    private var visible: [SessionSummary] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return sessions }
        return sessions.filter { summary in
            summary.displayTitle.localizedCaseInsensitiveContains(needle)
                || (summary.cwd ?? "").localizedCaseInsensitiveContains(needle)
                || summary.sessionId.localizedCaseInsensitiveContains(needle)
        }
    }

    private func reload() {
        sessions = sidecar.recentSessions(includeBlank: showBlank,
                                          onlyCurrentWorkspace: onlyCurrentWorkspace)
    }
}
