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
}

@MainActor
final class ConversationModel: ObservableObject {
    @Published private(set) var rows: [TranscriptRow] = []
    @Published private(set) var pendingPermission: PendingPermission?
    @Published private(set) var isWorking = false
    @Published var ruleSet: RuleSet = RuleSet()
    @Published var policyMode: PolicyMode = .strict
    /// 当前工作区根目录（规则的 workspace 边界）。
    @Published var workspaceRoot: String?

    private var assistantIndexByMessageID: [String: Int] = [:]

    final class PendingPermission: Identifiable {
        let id = UUID()
        let params: PermissionRequestParams
        fileprivate let continuation: CheckedContinuation<PermissionResponse, Never>

        init(params: PermissionRequestParams, continuation: CheckedContinuation<PermissionResponse, Never>) {
            self.params = params
            self.continuation = continuation
        }
    }

    func makeAnswerer() -> PermissionAnswerer {
        UIAnswerer(model: self)
    }

    /// 把一次反向审批请求挂到 UI，并保存其续体（仅 MainActor）。
    func enqueuePending(params: PermissionRequestParams,
                        continuation: CheckedContinuation<PermissionResponse, Never>) {
        pendingPermission = PendingPermission(params: params, continuation: continuation)
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
            if let text = update.content?.text, !text.isEmpty {
                upsertAssistant(messageID: update.messageId, text: text)
            }
        case SessionUpdateEvent.Kind.agentThoughtChunk:
            // 推理/思考块 v1 不展示，避免与正式回复混淆。
            break
        case SessionUpdateEvent.Kind.toolCall:
            rows.append(TranscriptRow(
                kind: .tool,
                text: update.title ?? update.toolCallId ?? "工具调用",
                status: update.status ?? "in_progress",
                messageID: update.toolCallId
            ))
        case SessionUpdateEvent.Kind.toolCallUpdate:
            if let id = update.toolCallId,
               let index = rows.firstIndex(where: { $0.messageID == id }) {
                rows[index].status = update.status ?? rows[index].status
            }
        default:
            // usage_update / config_option_update 等：v1 忽略。
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
}

/// ACP 反向审批请求的 UI 桥接：rules 模式命中规则自动放行；closed 模式拒绝；其余进审批卡。
private final class UIAnswerer: PermissionAnswerer {
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
                    // dsh 0.2 的审批请求只携带 toolCallId，没有命令文本；
                    // 无命令可匹配时不做规则自动放行，落入审批卡（fail-closed）。
                    let command = request.toolCall.rawCommand ?? ""
                    if !command.isEmpty {
                        let invocation = CommandInvocation(
                            tool: request.toolCall.kind ?? "bash",
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
