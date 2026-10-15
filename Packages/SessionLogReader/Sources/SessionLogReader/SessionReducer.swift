import Foundation
import AcpClient

/// App 侧会话轻状态（ACP update 通知与 JSONL 事件共用同一归约器）。
public enum AgentStatus: String, Sendable, Equatable {
    case idle
    case running
    case awaitingApproval
    case cancelled
    case failed
}

public struct MessageItem: Sendable, Equatable {
    public var id: String
    public var role: String          // assistant / user / reasoning
    public var text: String
}

public struct ToolCallItem: Sendable, Equatable {
    public var id: String
    public var title: String?
    public var command: String?
    public var kind: String?
    public var status: String?
    public var path: String?
}

public struct PlanItem: Sendable, Equatable {
    public var title: String
    public var status: String
}

public struct SessionViewState: Sendable, Equatable {
    public var status: AgentStatus = .idle
    public var messages: [MessageItem] = []
    public var toolCalls: [ToolCallItem] = []
    public var plan: [PlanItem] = []
    public var stopReason: String?
    public var lastError: String?

    public init() {}
}

/// 纯函数归约：把一条 JSONL 事件折叠进会话视图。
/// JSONL schema 在 RC 阶段可能变化，这里对多种字段形态做容忍；字段级冻结是 M0 的 P-2 任务。
public enum SessionReducer {

    public static func reduce(state: inout SessionViewState, event: LogEvent) {
        guard let kind = event.kind else { return }
        let payload = event.payload

        switch kind {
        case "session/start", "session/new", "turn/start", "prompt/start":
            state.status = .running
            state.lastError = nil

        case "assistant/text", "assistant/message", "assistant/chunk", "message/assistant":
            state.status = .running
            appendMessage(&state,
                          id: string(payload, "messageId", "id") ?? "a-\(state.messages.count)",
                          role: string(payload, "role") ?? "assistant",
                          text: extractText(payload))

        case "reasoning", "assistant/reasoning", "thinking":
            appendMessage(&state,
                          id: "reasoning-\(state.messages.count)",
                          role: "reasoning",
                          text: extractText(payload))

        case "user/message", "user/text", "message/user":
            appendMessage(&state,
                          id: string(payload, "messageId", "id") ?? "u-\(state.messages.count)",
                          role: "user",
                          text: extractText(payload))

        case "tool/call", "tool_call", "toolCall", "tool/started":
            if let item = parseToolCall(payload, fallback: event.json) {
                upsertToolCall(&state, item)
            }

        case "tool/result", "tool/finished", "toolCallUpdate", "tool/update":
            let id = string(payload, "toolCallId", "id")
            let status = string(payload, "status", "state")
            if let index = id.flatMap({ id in state.toolCalls.firstIndex(where: { $0.id == id }) }) {
                if let status { state.toolCalls[index].status = status }
            } else if let item = parseToolCall(payload, fallback: event.json) {
                upsertToolCall(&state, item)
            }

        case "permission/request", "approval/request", "session/request_permission":
            state.status = .awaitingApproval

        case "permission/resolved", "approval/resolved":
            state.status = .running

        case "session/cancel", "turn/cancel", "cancelled":
            state.status = .cancelled

        case "turn/end", "prompt/end", "session/prompt/end":
            let reason = string(payload, "stopReason", "reason", "finishReason") ?? "end_turn"
            state.stopReason = reason
            state.status = (reason == "cancelled") ? .cancelled
                         : (reason.contains("error")) ? .failed : .idle

        case "error", "turn/error", "session/error":
            state.status = .failed
            state.lastError = string(payload, "message", "error") ?? "未知错误"

        case "plan/update", "plan":
            if let entries = payload["entries"]?.arrayValue {
                state.plan = entries.compactMap { entry in
                    guard let title = entry.stringValue ?? entry["content"]?.stringValue
                            ?? entry["title"]?.stringValue else { return nil }
                    return PlanItem(title: title,
                                    status: entry["status"]?.stringValue
                                        ?? entry["type"]?.stringValue ?? "pending")
                }
            }

        default:
            break // 未识别事件忽略，不影响状态机
        }
    }

    public static func reduceAll(events: [LogEvent], initial: SessionViewState = SessionViewState()) -> SessionViewState {
        var state = initial
        events.forEach { reduce(state: &state, event: $0) }
        return state
    }

    // MARK: - helpers

    private static func appendMessage(_ state: inout SessionViewState,
                                      id: String, role: String, text: String?) {
        guard let text, !text.isEmpty else { return }
        if let index = state.messages.firstIndex(where: { $0.id == id && $0.role == role }) {
            state.messages[index].text += text
        } else {
            state.messages.append(MessageItem(id: id, role: role, text: text))
        }
    }

    private static func upsertToolCall(_ state: inout SessionViewState, _ item: ToolCallItem) {
        if let index = state.toolCalls.firstIndex(where: { $0.id == item.id }) {
            var existing = state.toolCalls[index]
            existing.title = item.title ?? existing.title
            existing.command = item.command ?? existing.command
            existing.kind = item.kind ?? existing.kind
            existing.status = item.status ?? existing.status
            existing.path = item.path ?? existing.path
            state.toolCalls[index] = existing
        } else {
            state.toolCalls.append(item)
        }
    }

    private static func parseToolCall(_ payload: JSONValue, fallback: JSONValue?) -> ToolCallItem? {
        // 形态 A：payload 自身即 toolCall；形态 B：payload.toolCall 嵌套；形态 C：扁平在行上。
        let source: JSONValue = payload["toolCall"] ?? payload["call"] ?? payload
        let obj = source.objectValue ?? fallback?.objectValue
        guard let obj else { return nil }
        let id = obj["id"]?.stringValue ?? obj["toolCallId"]?.stringValue
            ?? obj["id"]?.intValue.map(String.init)
        guard let id else { return nil }
        return ToolCallItem(
            id: String(id),
            title: obj["title"]?.stringValue,
            command: obj["rawCommand"]?.stringValue ?? obj["command"]?.stringValue,
            kind: obj["kind"]?.stringValue,
            status: obj["status"]?.stringValue,
            path: obj["location"]?["path"]?.stringValue ?? obj["path"]?.stringValue
        )
    }

    /// 支持 {text:"..."} 与 {content:[{type:"text",text:"..."}]} 两种形态。
    private static func extractText(_ payload: JSONValue) -> String? {
        if let text = payload["text"]?.stringValue { return text }
        if let blocks = payload["content"]?.arrayValue {
            return blocks.compactMap { $0["text"]?.stringValue }.joined()
        }
        return payload.stringValue
    }

    private static func string(_ value: JSONValue, _ keys: String...) -> String? {
        for key in keys {
            if let result = value[key]?.stringValue { return result }
        }
        return nil
    }
}
