import Foundation
import Combine
import AcpClient
import PolicyEngine
import Persistence

/// 一条展示面轨迹行（富内容真相源仍是 JSONL，这里只服务当前会话 UI）。
struct TranscriptRow: Identifiable {
    enum Kind {
        case user
        case assistant
        case tool
        case plan
        case system
    }

    let id = UUID()
    var kind: Kind
    var text: String
    var status: String?
    var messageID: String?
    /// 工具调用的**完整**结果文本（对话流里只放截断预览，展开时才显示）。
    /// nil = 没有结果或结果短到不值得折叠。
    var fullResult: String?
}

@MainActor
final class ConversationModel: ObservableObject {
    @Published private(set) var rows: [TranscriptRow] = []
    @Published private(set) var pendingPermission: PendingPermission?
    @Published private(set) var isWorking = false
    /// usage_update 事件上报的上下文占用（used / size）。
    @Published private(set) var usage: (used: Int64, size: Int64)?
    @Published var ruleSet: RuleSet = RuleSet()
    @Published var policyMode: PolicyMode = .strict
    /// 当前工作区根目录（规则的 workspace 边界）。
    @Published var workspaceRoot: String?

    /// toolCallId → 快照。dsh 0.2 的 request_permission 只带 toolCallId，
    /// 命令文本必须由先行的 tool_call 事件按 ID 补给（见 ToolCallTracker 注释）。
    /// 该实例同时注入 AcpConnection：分帧路径同步记录以保证与审批请求同序；
    /// 这里的 record 是幂等兜底（未接线 tracker 的客户端也能展示）。
    let toolCalls = ToolCallTracker()

    private var assistantIndexByMessageID: [String: Int] = [:]
    private var planRowID: UUID?

    final class PendingPermission: Identifiable {
        let id = UUID()
        let params: PermissionRequestParams
        /// 由 tool_call 事件补给的快照；nil 表示关联不上（fail-closed 走审批卡）。
        let snapshot: ToolCallSnapshot?
        fileprivate let continuation: CheckedContinuation<PermissionResponse, Never>

        init(params: PermissionRequestParams,
             snapshot: ToolCallSnapshot?,
             continuation: CheckedContinuation<PermissionResponse, Never>) {
            self.params = params
            self.snapshot = snapshot
            self.continuation = continuation
        }

        /// 审批卡展示的命令文本（关联失败时退化为工具标识）。
        var commandText: String {
            if let command = snapshot?.commandText, !command.isEmpty { return command }
            return params.toolCall.title ?? params.toolCall.primaryId ?? "未知工具调用"
        }

        var hasCommandText: Bool {
            guard let command = snapshot?.commandText else { return false }
            return !command.isEmpty
        }

        /// 工具名（dsh 0.2：tool_call 事件的 title）。
        var toolName: String {
            snapshot?.title ?? snapshot?.name ?? params.toolCall.kind ?? "bash"
        }
    }

    func makeAnswerer() -> PermissionAnswerer {
        UIAnswerer(model: self)
    }

    /// 把一次反向审批请求挂到 UI，并保存其续体（仅 MainActor）。
    func enqueuePending(params: PermissionRequestParams,
                        continuation: CheckedContinuation<PermissionResponse, Never>) {
        let snapshot = params.toolCall.primaryId.flatMap { toolCalls.snapshot(for: $0) }
            ?? toolCalls.latestSnapshot()
        pendingPermission = PendingPermission(params: params, snapshot: snapshot, continuation: continuation)
    }

    func respond(_ response: PermissionResponse) {
        guard let pending = pendingPermission else { return }
        pendingPermission = nil
        pending.continuation.resume(returning: response)
        if case .selected = response.status {
            let allowed = response.optionId?.localizedCaseInsensitiveContains("allow") == true
            rows.append(TranscriptRow(kind: .system,
                                      text: "已\(allowed ? "允许" : "拒绝")本次工具调用"))
        } else {
            rows.append(TranscriptRow(kind: .system, text: "审批已取消（fail-closed：不放行）"))
        }
    }

    /// 审批卡出口「在终端运行」：对 ACP 回 **reject**（dsh 不执行），
    /// 命令改由 App 注入终端执行并回喂输出。
    ///
    /// 为什么不 allow + 也注入终端：那样命令会跑两遍（dsh 一遍、PTY 一遍），
    /// 副作用双倍——`rm -rf` / `git push` 类命令出一次事故就够记一辈子。
    /// reject 是这里唯一安全语义。
    func respondRunInTerminal() {
        guard let pending = pendingPermission else { return }
        pendingPermission = nil
        pending.continuation.resume(returning: pending.params.responseRejecting())
        rows.append(TranscriptRow(kind: .system,
                                  text: "已拒绝 agent 直接执行，命令改在终端运行"))
    }

    // MARK: 终端命令审批门（MCP run_in_terminal）

    /// 终端 MCP 工具的挂起审批。与 PendingPermission 是两套机制：
    /// 那边应答的是 ACP `session/request_permission`（dsh 发起），这边是
    /// App 自己的门（tools/call 到达 TerminalMCPServer 时发起）——
    /// 因为 MCP 工具在 dsh 侧不走审批（实证：dsh-mcp-client 无任何审批逻辑，
    /// tools/pre-execute 默认 allow），门只能做在 App 侧。
    final class PendingTerminalCommand: Identifiable {
        let id = UUID()
        let command: String
        /// 命令将要注入的**执行目标**：哪台机器、哪个目录。
        ///
        /// 旧实现只有 `target: String?`（一个展示名）+ `workspaceRoot`（本地路径）。
        /// SSH 会话下这两样凑不出一条完整信息：用户看不出命令落在远端哪个目录，
        /// 而 `workspaceRoot` 在远程场景里是个无关的本地路径。
        let execution: CommandExecutionTarget
        /// agent 的**本地**文件域（远程会话下与执行目录不是一回事）。
        let localWorkspaceRoot: String?
        /// 服务端（TerminalMCPServer）传入的应答闭包；它在 withCheckedContinuation
        /// 里 resume，所以这里只存闭包，不持有 continuation。
        fileprivate let completion: (TerminalCommandDecision) -> Void

        init(command: String,
             execution: CommandExecutionTarget,
             localWorkspaceRoot: String?,
             completion: @escaping (TerminalCommandDecision) -> Void) {
            self.command = command
            self.execution = execution
            self.localWorkspaceRoot = localWorkspaceRoot
            self.completion = completion
        }
    }

    @Published private(set) var pendingTerminalCommand: PendingTerminalCommand?

    /// TerminalCommandGate 实现：closed 全拒；rules 命中规则自动放行；
    /// 其余（strict 或 rules 未命中）弹审批卡等人。
    func requestTerminalCommand(_ command: String,
                                execution: CommandExecutionTarget,
                                completion: @escaping (TerminalCommandDecision) -> Void) {
        switch policyMode {
        case .closed:
            appendSystem("闭关模式：已自动拒绝 agent 的终端命令请求")
            completion(.reject)
            return
        case .rules:
            // 远程会话**不做**越界判定：`workspaceRoot` 是本地路径，拿它去比
            // 远端的绝对路径只会把所有远程命令都标成"访问工作区之外"（纯噪音，
            // 而且会训练用户无视这个标签）。真正的远端边界要另开一条 ssh 才能
            // 验证，成本与收益不成比例；此时传 nil 让规则只按命令模式匹配，
            // 方向是保守的（该弹卡照样弹卡）。
            let localRoot = execution.isRemote ? nil : workspaceRoot
            let invocation = CommandInvocation(
                tool: TerminalMCP.toolName,
                command: command,
                cwd: execution.directory ?? localRoot,
                workspaceRoot: localRoot
            )
            if let rule = ruleSet.automaticAllow(for: invocation) {
                appendSystem("规则命中自动允许：\(rule.pattern)")
                completion(.allow)
                return
            }
        case .strict:
            break
        }
        appendSystem(execution.isRemote
                     ? "agent 请求在远程终端执行命令（\(execution.summary)），等待审批…"
                     : "agent 请求在终端执行命令，等待审批…")
        pendingTerminalCommand = PendingTerminalCommand(
            command: command,
            execution: execution,
            localWorkspaceRoot: workspaceRoot,
            completion: completion
        )
    }

    /// 旧签名（只有展示名）：测试与旧调用点用。远程信息缺失时按本地处理——
    /// 宁可少一个标注，也不能凭一个字符串猜"这是不是远程"。
    func requestTerminalCommand(_ command: String,
                                target: String?,
                                completion: @escaping (TerminalCommandDecision) -> Void) {
        requestTerminalCommand(
            command,
            execution: CommandExecutionTarget(label: target ?? CommandExecutionTarget.localDefault.label,
                                              directory: workspaceRoot,
                                              isRemote: false),
            completion: completion
        )
    }

    /// 服务端超时放弃：fail-closed 了结（用户迟到点"允许"时 pending 已清，no-op）。
    func cancelTerminalCommandRequest() {
        guard let pending = pendingTerminalCommand else { return }
        pendingTerminalCommand = nil
        pending.completion(.reject)
        appendSystem("终端命令审批超时，已作废（fail-closed：未执行）")
    }

    /// 审批卡出口。
    func respondTerminalCommand(allow: Bool) {
        guard let pending = pendingTerminalCommand else { return }
        pendingTerminalCommand = nil
        pending.completion(allow ? .allow : .reject)
        if allow {
            appendSystem("已允许：命令正在你的终端里执行")
        } else {
            appendSystem("已拒绝：命令未执行")
        }
    }

    // MARK: - session/update 接入

    func handleNotification(method: String, data: Data?) {
        guard method == AcpMethod.sessionUpdate, let data else { return }
        guard let params = try? JSONDecoder.acp.decode(SessionNotificationParams.self, from: data),
              let update = params.update else {
            return
        }

        switch update.sessionUpdate {
        case SessionUpdateEvent.Kind.agentMessageChunk:
            // dsh 按消息块下发；同 messageId 的文本合并为一行流式回复。
            if let text = update.textContent, !text.isEmpty {
                upsertAssistant(messageID: update.messageId, text: text)
            }
        case SessionUpdateEvent.Kind.userMessageChunk:
            break // 用户消息本地已回显
        case SessionUpdateEvent.Kind.agentThoughtChunk:
            break // 推理/思考块 v1 不展示，避免与正式回复混淆
        case SessionUpdateEvent.Kind.toolCall:
            toolCalls.record(update)
            let snapshot = update.toolCallId.flatMap { toolCalls.snapshot(for: $0) }
            rows.append(TranscriptRow(
                kind: .tool,
                text: snapshot?.displayTitle ?? update.title ?? "工具调用",
                status: update.status ?? "in_progress",
                messageID: update.toolCallId
            ))
        case SessionUpdateEvent.Kind.toolCallUpdate:
            toolCalls.record(update)
            if let id = update.toolCallId,
               let index = rows.firstIndex(where: { $0.messageID == id }) {
                rows[index].status = update.status ?? rows[index].status
                if let result = update.resultText, !result.isEmpty {
                    // 长结果折叠（2026-10-17 用户反馈「输出淹进对话流」）：
                    // 构建日志 / glob 结果动辄几百行，直接 += 进聊天区会把对话冲垮，
                    // 而这些输出本该进终端面板（等宽、可滚动、可搜索）。
                    // 行内放截断预览，完整文本留档在 fullResult，UI 按需展开。
                    let preview = Self.resultPreview(result)
                    rows[index].text += "\n→ \(preview)"
                    if preview != result {
                        rows[index].fullResult = result
                    }
                }
            }
        case SessionUpdateEvent.Kind.plan, SessionUpdateEvent.Kind.planUpdate:
            if let entries = update.planEntries {
                upsertPlan(entries.map { entry in
                    "\(Self.planMark(entry.status)) \(entry.content)"
                }.joined(separator: "\n"))
            }
        case SessionUpdateEvent.Kind.usageUpdate:
            if let used = update.used, let size = update.size {
                usage = (used, size)
            }
        default:
            // available_commands_update / session_info_update / compaction_* 等：v1 忽略。
            //
            // config_option_update **不在这里**：选项集由 SidecarService 单独持有
            // （会话级状态与会话同生命周期），它在上游 consume() 里先截下来更新
            // 自己再转发过来。若这里也存一份，两边必然出现不一致。
            break
        }
    }

    func appendSystem(_ text: String) {
        rows.append(TranscriptRow(kind: .system, text: text))
    }

    func setWorking(_ working: Bool) {
        isWorking = working
    }

    func appendUser(_ text: String) {
        rows.append(TranscriptRow(kind: .user, text: text))
    }

    /// 直接落一条助手消息。
    ///
    /// 正常路径是 ACP 的 `agentMessageChunk` 逐块累积（见 `handleUpdate`）；
    /// 这个方法给两类调用者：外观回归脚本（`--demo-transcript`）与单元测试——
    /// 它们需要「一条已经完整的助手消息」，而不是自己伪造一串事件。
    func appendAssistant(_ text: String) {
        rows.append(TranscriptRow(kind: .assistant, text: text))
    }

    func handlePromptResult(_ result: PromptResult) {
        isWorking = false
        if result.stopReason != "request_permission" && result.stopReason != "end_turn" {
            rows.append(TranscriptRow(kind: .system, text: "会话结束：\(result.stopReason)"))
        }
        if let error = result.stopError {
            rows.append(TranscriptRow(kind: .system,
                                      text: "sidecar 错误：\(error.code ?? "") \(error.message ?? "")"))
        }
    }

    /// 新开会话/恢复会话：清空当前展示面与关联缓存。
    func beginSession() {
        rows.removeAll()
        assistantIndexByMessageID.removeAll()
        planRowID = nil
        usage = nil
        expandedResultRows.removeAll()
        toolCalls.clear()
        // 挂起的终端命令审批跟着旧会话一起作废（fail-closed：不执行）。
        if pendingTerminalCommand != nil {
            cancelTerminalCommandRequest()
        }
    }

    // MARK: 工具结果折叠（对话流只放预览，完整输出按需展开）

    /// 展开了完整工具输出的行 id。默认折叠——长结果不进对话流。
    @Published private(set) var expandedResultRows: Set<UUID> = []

    func isResultExpanded(_ id: UUID) -> Bool {
        expandedResultRows.contains(id)
    }

    func toggleResultExpansion(_ id: UUID) {
        if expandedResultRows.contains(id) {
            expandedResultRows.remove(id)
        } else {
            expandedResultRows.insert(id)
        }
    }

    /// 工具结果的对话流预览：超过阈值就截断，尾部标注余量。
    ///
    /// 阈值取「一眼能看完」的量级（6 行 / 600 字符）。宁少勿多：预览的职责是
    /// 让用户判断**要不要看完整输出**，不是替代完整输出。
    static func resultPreview(_ result: String, maxLines: Int = 6, maxChars: Int = 600) -> String {
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines || result.count > maxChars else { return result }
        let head = lines.prefix(maxLines).joined(separator: "\n")
        let remainingLines = lines.count - min(lines.count, maxLines)
        return head + "\n…（余 \(remainingLines) 行 / 共 \(result.count) 字符）"
    }

    private func upsertAssistant(messageID: String?, text: String) {
        if let messageID, let index = assistantIndexByMessageID[messageID] {
            // 流式 chunk：同 messageId 合并。
            rows[index].text += text
        } else {
            let index = rows.count
            rows.append(TranscriptRow(kind: .assistant, text: text, messageID: messageID))
            if let messageID { assistantIndexByMessageID[messageID] = index }
        }
    }

    private func upsertPlan(_ text: String) {
        if let planRowID, let index = rows.firstIndex(where: { $0.id == planRowID }) {
            rows[index].text = text
        } else {
            let row = TranscriptRow(kind: .plan, text: text)
            planRowID = row.id
            rows.append(row)
        }
    }

    private static func planMark(_ status: String) -> String {
        switch status {
        case "completed": return "✅"
        case "in_progress": return "🔶"
        case "failed": return "❌"
        case "pending": return "⬜"
        default: return "•"
        }
    }
}

/// ACP 反向审批请求的 UI 桥接：rules 模式命中规则自动放行；closed 模式拒绝；其余进审批卡。
/// rules 模式的命令文本来自 ToolCallTracker（dsh 审批请求只带 toolCallId）。
/// `model` 为 weak 且在 init 后不再变更，读写都发生在 MainActor（answer 内先 hop 再访问）——
/// 人工保证线程安全，故显式 @unchecked Sendable。
private final class UIAnswerer: PermissionAnswerer, @unchecked Sendable {
    weak var model: ConversationModel?

    init(model: ConversationModel) {
        self.model = model
    }

    func answer(_ request: PermissionRequestParams) async -> PermissionResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<PermissionResponse, Never>) in
            Task { @MainActor [weak self] in
                guard let model = self?.model else {
                    continuation.resume(returning: .reject())
                    return
                }

                switch model.policyMode {
                case .closed:
                    continuation.resume(returning: .reject())
                    return
                case .rules:
                    // 命令文本由 tool_call 事件补给；关联不上就不做规则自动放行（fail-closed）。
                    let snapshot = request.toolCall.primaryId.flatMap { model.toolCalls.snapshot(for: $0) }
                        ?? model.toolCalls.latestSnapshot()
                    if let command = snapshot?.commandText, !command.isEmpty {
                        let invocation = CommandInvocation(
                            tool: snapshot?.title ?? snapshot?.name ?? "bash",
                            command: command,
                            cwd: model.workspaceRoot,
                            workspaceRoot: model.workspaceRoot
                        )
                        if let rule = model.ruleSet.automaticAllow(for: invocation) {
                            model.appendSystem("规则命中自动允许：\(rule.pattern)")
                            continuation.resume(returning: request.responseAllowing())
                            return
                        }
                    }
                case .strict:
                    break
                }

                // strict 或 rules 未命中：弹原生审批卡，等待用户。
                model.enqueuePending(params: request, continuation: continuation)
            }
        }
    }
}

/// ConversationModel 即终端命令审批门（协议定义在 TerminalMCPServer.swift）。
/// 门语义与 ACP 审批卡一致：closed 全拒、rules 命中放行、其余弹卡。
extension ConversationModel: TerminalCommandGate {}
