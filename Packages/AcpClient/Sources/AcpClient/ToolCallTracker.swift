import Foundation

/// dsh 0.2 线格式实证（App/Resources/runtime/node_modules/@deepseek-ai/dsh-acp/lib/index.js）：
/// - `tool_call` 事件：`{toolCallId, title:<工具名>, kind:"other", status:"in_progress", rawInput:<参数对象>}`
/// - `tool_call_update`：`{toolCallId, status:"completed"|"failed", content:[ToolCallContent]}`
/// - `session/request_permission`：`{sessionId, toolCall:{toolCallId}, options:[…]}` —— **只带 toolCallId**。
///
/// 因此审批卡/规则引擎要拿命令文本，必须由先行的 `tool_call` 事件按 toolCallId 补给。
/// Tracker 是这条关联链的单一事实源；纯值类型 + 锁，App 与测试共用。
public struct ToolCallSnapshot: Sendable, Equatable {
    public var toolCallId: String
    /// dsh 0.2：title = 工具名（如 "bash"）。
    public var title: String?
    /// UNSTABLE 程序化工具名（部分构建下发）。
    public var name: String?
    public var kind: String?
    public var status: String?
    public var rawInput: JSONValue?
    public var locations: [ToolCallLocation]
    /// 提取的命令/目标文本（bash → rawInput.command；fs → path；兜底 compact JSON）。
    public var commandText: String?
    /// tool_call_update 带来的结果文本（v1 展示用）。
    public var resultText: String?

    public init(toolCallId: String,
                title: String? = nil,
                name: String? = nil,
                kind: String? = nil,
                status: String? = nil,
                rawInput: JSONValue? = nil,
                locations: [ToolCallLocation] = [],
                commandText: String? = nil,
                resultText: String? = nil) {
        self.toolCallId = toolCallId
        self.title = title
        self.name = name
        self.kind = kind
        self.status = status
        self.rawInput = rawInput
        self.locations = locations
        self.commandText = commandText
        self.resultText = resultText
    }

    /// 轨迹行/审批卡标题：`bash · rm -rf build/`。
    public var displayTitle: String {
        let tool = title ?? name ?? kind ?? "工具"
        if let commandText, !commandText.isEmpty {
            return "\(tool) · \(commandText)"
        }
        return tool
    }

    /// 用于风险判定与规则匹配的调用描述（tool + command）。
    public var invocation: (tool: String, command: String) {
        (title ?? name ?? kind ?? "bash", commandText ?? "")
    }
}

public enum ToolCallCommandExtractor {
    /// 命令文本提取优先级：
    /// 1. rawInput.command / cmd / script（bash 家族）
    /// 2. rawInput.path / file_path / filename（fs/str_replace_editor 家族）
    /// 3. rawInput 紧凑 JSON（未知工具兜底，绝不返回 nil 之外的猜测）
    public static func command(from rawInput: JSONValue?) -> String? {
        guard let rawInput else { return nil }
        if let obj = rawInput.objectValue {
            for key in ["command", "cmd", "script"] {
                if let value = obj[key]?.stringValue, !value.isEmpty { return value }
            }
            for key in ["path", "file_path", "filePath", "filename"] {
                if let value = obj[key]?.stringValue, !value.isEmpty { return value }
            }
        }
        return compactJSON(rawInput)
    }

    /// 单行紧凑 JSON（未知工具的参数兜底展示）。
    public static func compactJSON(_ value: JSONValue) -> String? {
        guard let data = try? JSONEncoder.acp.encode(value) else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if text.count > 500 {
            text = String(text.prefix(500)) + "…"
        }
        return text
    }
}

/// toolCallId → 快照 的关联缓存。通知到达与审批请求到达不在同一帧，
/// 这里把 `tool_call` 事件的情报hold住，供 request_permission 到达时取用。
public final class ToolCallTracker: @unchecked Sendable {
    private var snapshots: [String: ToolCallSnapshot] = [:]
    /// 插入序（字典无序，"最近一次"按此判定）。
    private var order: [String] = []
    private let lock = NSLock()

    public init() {}

    /// 归约一条 session/update 事件（tool_call / tool_call_update；其余忽略）。
    public func record(_ event: SessionUpdateEvent) {
        guard let id = event.toolCallId else { return }
        lock.lock(); defer { lock.unlock() }

        var snapshot = snapshots[id] ?? ToolCallSnapshot(toolCallId: id)
        if snapshots[id] == nil { order.append(id) }
        switch event.sessionUpdate {
        case SessionUpdateEvent.Kind.toolCall:
            snapshot.title = event.title ?? snapshot.title
            snapshot.name = event.name ?? snapshot.name
            snapshot.kind = event.kind ?? snapshot.kind
            snapshot.status = event.status ?? snapshot.status
            snapshot.rawInput = event.rawInput ?? snapshot.rawInput
            if let locations = event.locations { snapshot.locations = locations }
            snapshot.commandText = ToolCallCommandExtractor.command(from: snapshot.rawInput)
        case SessionUpdateEvent.Kind.toolCallUpdate:
            snapshot.status = event.status ?? snapshot.status
            if let text = event.resultText { snapshot.resultText = text }
        default:
            break
        }
        snapshots[id] = snapshot
    }

    public func snapshot(for toolCallId: String) -> ToolCallSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshots[toolCallId]
    }

    /// 最近一次快照（兜底：审批请求缺 toolCallId 时展示最近活动调用）。
    public func latestSnapshot() -> ToolCallSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let last = order.last else { return nil }
        return snapshots[last]
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        snapshots.removeAll()
        order.removeAll()
    }
}
