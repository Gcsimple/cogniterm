import Foundation

// MARK: - initialize

public struct ClientInfo: Codable, Sendable {
    public var name: String
    public var version: String
    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct FsCapability: Codable, Sendable {
    public var readTextFile: Bool?
    public init(readTextFile: Bool? = true) { self.readTextFile = readTextFile }
}

public struct ClientCapabilities: Codable, Sendable {
    public var fs: FsCapability?
    public init(fs: FsCapability? = nil) { self.fs = fs }
}

public struct InitializeParams: Codable, Sendable {
    public var protocolVersion: Int
    public var clientCapabilities: ClientCapabilities
    public var clientInfo: ClientInfo
    public init(protocolVersion: Int = 1,
                clientCapabilities: ClientCapabilities = .init(),
                clientInfo: ClientInfo) {
        self.protocolVersion = protocolVersion
        self.clientCapabilities = clientCapabilities
        self.clientInfo = clientInfo
    }
}

public struct AgentCapabilities: Codable, Sendable {
    public var loadSession: Bool?
    public init(loadSession: Bool? = nil) { self.loadSession = loadSession }
}

public struct InitializeResult: Codable, Sendable {
    public var protocolVersion: Int
    public var capabilities: AgentCapabilities?
    /// 真实 dsh 0.2.x 返回 agentInfo；早期 ACP 草案字段为 serverInfo。两者皆收。
    public var serverInfo: ClientInfo
    public var instructions: String?
    public var authMethods: [String]?

    // 显式成员初始化仅供测试与预构造使用
    public init(protocolVersion: Int,
                capabilities: AgentCapabilities? = nil,
                serverInfo: ClientInfo,
                instructions: String? = nil,
                authMethods: [String]? = nil) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
        self.authMethods = authMethods
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, capabilities, serverInfo, agentInfo, instructions, authMethods
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        capabilities = try? c.decode(AgentCapabilities.self, forKey: .capabilities)
        serverInfo = try c.decodeIfPresent(ClientInfo.self, forKey: .serverInfo)
            ?? c.decode(ClientInfo.self, forKey: .agentInfo)
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions)
        authMethods = try c.decodeIfPresent([String].self, forKey: .authMethods)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encodeIfPresent(capabilities, forKey: .capabilities)
        try c.encode(serverInfo, forKey: .serverInfo)
        try c.encodeIfPresent(instructions, forKey: .instructions)
        try c.encodeIfPresent(authMethods, forKey: .authMethods)
    }
}

// MARK: - sessions

public struct PromptBlock: Codable, Sendable {
    public var type: String          // "text"
    public var text: String?
    public init(type: String = "text", text: String?) {
        self.type = type
        self.text = text
    }
}

public struct ModelSelection: Codable, Sendable {
    public var providerId: String?
    public var id: String?
    public init(providerId: String? = nil, id: String?) {
        self.providerId = providerId
        self.id = id
    }
}

/// stdio 型 MCP server 声明；HTTP/SSE 由 url 承载（0.2 支持 stdio/HTTP）。
public struct McpServerConfig: Codable, Sendable {
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    public init(command: String? = nil,
                args: [String]? = nil,
                env: [String: String]? = nil,
                url: String? = nil) {
        self.command = command
        self.args = args
        self.env = env
        self.url = url
    }
}

public struct SessionNewParams: Codable, Sendable {
    public var cwd: String
    /// 真实 dsh 要求该字段必传（空对象表示无外挂 MCP）；缺省会返回 -32602。
    public var mcpServers: [String: McpServerConfig]
    public var model: ModelSelection?
    public var reasoningEffort: String?

    public init(cwd: String,
                mcpServers: [String: McpServerConfig]? = nil,
                model: ModelSelection? = nil,
                reasoningEffort: String? = nil) {
        self.cwd = cwd
        self.mcpServers = mcpServers ?? [:]
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct SessionNewResult: Codable, Sendable {
    public var sessionId: String?
}

public struct SessionPromptParams: Codable, Sendable {
    public var sessionId: String
    public var prompt: [PromptBlock]
    public init(sessionId: String, prompt: [PromptBlock]) {
        self.sessionId = sessionId
        self.prompt = prompt
    }
}

public struct PromptErrorInfo: Codable, Sendable {
    public var code: String?
    public var message: String?
}

public struct PromptResult: Codable, Sendable {
    /// end_turn / request_permission / cancelled / max_tokens_error 等。
    public var stopReason: String
    public var stopError: PromptErrorInfo?
}

public struct CancelParams: Codable, Sendable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

public struct CloseParams: Codable, Sendable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

// MARK: - list / resume

public struct SessionInfo: Codable, Sendable, Identifiable {
    public var sessionId: String
    public var cwd: String?
    public var title: String?
    public var id: String { sessionId }
}

public struct SessionListResult: Codable, Sendable {
    public var sessions: [SessionInfo]
}

public struct SessionResumeParams: Codable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var mcpServers: [String: McpServerConfig]
    public init(sessionId: String,
                cwd: String? = nil,
                mcpServers: [String: McpServerConfig]? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers ?? [:]
    }
}

// MARK: - request_permission（server → client）

public struct ToolCall: Codable, Sendable {
    public var id: String?
    public var toolCallId: String?
    public var kind: String?            // "execute" / "view" ...
    public var title: String?
    public var rawCommand: String?
    public var status: String?
    public var location: ToolCallLocation?
}

public struct ToolCallLocation: Codable, Sendable {
    public var path: String?
    public var line: Int?
}

/// dsh 0.2 实际线格式：option 以 optionId 标识（如 "allow-once" / "reject-once"）。
public struct PermissionOption: Codable, Sendable {
    public var optionId: String
    public var name: String?
    public var kind: String?            // "allow_once" / "reject_once" / 服务端自定义
    public init(optionId: String, name: String? = nil, kind: String? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

public struct PermissionRequestParams: Codable, Sendable {
    public var sessionId: String
    /// dsh 0.2 只带 toolCallId；命令明细通过 session/update 的 tool_call 事件呈现。
    public var toolCall: ToolCall
    public var options: [PermissionOption] = []
}

/// ACP `session/request_permission` 的应答，线格式为嵌套：
/// `{ "outcome": { "outcome": "selected"|"cancelled", "optionId": "allow-once" } }`
public struct PermissionResponse: Codable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case selected
        case cancelled
    }

    public struct Body: Codable, Sendable {
        public var outcome: Outcome
        public var optionId: String?
    }

    public var outcome: Body

    public init(outcome: Outcome, optionId: String? = nil) {
        self.outcome = Body(outcome: outcome, optionId: optionId)
    }

    public var status: Outcome { outcome.outcome }
    public var optionId: String? { outcome.optionId }

    /// dsh 0.2 内置审批选项 ID；若服务端广告了其他 ID，优先使用
    /// PermissionRequestParams.responseAllowing/Rejecting 按请求选项应答。
    public static func allow() -> PermissionResponse {
        PermissionResponse(outcome: .selected, optionId: "allow-once")
    }

    public static func reject() -> PermissionResponse {
        PermissionResponse(outcome: .selected, optionId: "reject-once")
    }

    public static func cancel() -> PermissionResponse {
        PermissionResponse(outcome: .cancelled)
    }
}

public extension PermissionRequestParams {
    /// 按本次请求实际广告的选项构造“允许”应答（按 kind/optionId 匹配 allow 语义）。
    func responseAllowing() -> PermissionResponse {
        PermissionResponse(outcome: .selected, optionId: pickOption(allow: true) ?? "allow-once")
    }

    /// 按本次请求实际广告的选项构造“拒绝”应答。
    func responseRejecting() -> PermissionResponse {
        PermissionResponse(outcome: .selected, optionId: pickOption(allow: false) ?? "reject-once")
    }

    private func pickOption(allow: Bool) -> String? {
        let marker = allow ? "allow" : "reject"
        if let byKind = options.first(where: { ($0.kind ?? "").localizedCaseInsensitiveContains(marker) }) {
            return byKind.optionId
        }
        if let byId = options.first(where: { $0.optionId.localizedCaseInsensitiveContains(marker) }) {
            return byId.optionId
        }
        return options.first?.optionId
    }
}

// MARK: - session/update 通知（展示面轻状态；富内容以 JSONL 为准）

/// 线格式（dsh 0.2 实测）：
/// `{ "sessionId": "...", "update": { "sessionUpdate": "<kind>", ...事件字段 } }`
public struct SessionNotificationParams: Decodable, Sendable {
    public var sessionId: String?
    public var update: SessionUpdateEvent?
}

/// 扁平事件 + 字符串鉴别符。各变体只在对应 kind 下使用各自字段：
/// - agent_message_chunk / agent_thought_chunk: messageId + content（单个块）
/// - tool_call: toolCallId + title + kind + status + rawInput
/// - tool_call_update: toolCallId + status（+ content 结果块，v1 不展示）
/// - usage_update / config_option_update: v1 忽略
public struct SessionUpdateEvent: Decodable, Sendable {
    public enum Kind {
        public static let agentMessageChunk = "agent_message_chunk"
        public static let agentThoughtChunk = "agent_thought_chunk"
        public static let toolCall = "tool_call"
        public static let toolCallUpdate = "tool_call_update"
        public static let usageUpdate = "usage_update"
        public static let configOptionUpdate = "config_option_update"
    }

    public var sessionUpdate: String
    public var messageId: String?
    public var content: PromptBlock?
    public var toolCallId: String?
    public var title: String?
    public var kind: String?
    public var status: String?
    public var rawInput: JSONValue?
}

// MARK: - fs/readTextFile（server → client）

public struct FsReadTextFileParams: Codable, Sendable {
    public var path: String
}

public struct FsReadTextFileResult: Codable, Sendable {
    public var content: String
}

/// 无载荷 ACK（session/cancel、session/resume 等的应答体）。
public struct AcpAck: Codable, Sendable {
    public init() {}
}
