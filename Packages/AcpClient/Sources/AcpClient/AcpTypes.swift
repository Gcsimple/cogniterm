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
    public var writeTextFile: Bool?
    public init(readTextFile: Bool? = true, writeTextFile: Bool? = nil) {
        self.readTextFile = readTextFile
        self.writeTextFile = writeTextFile
    }
}

public struct ClientCapabilities: Codable, Sendable {
    public var fs: FsCapability?
    /// 是否支持 terminal/* 一族方法（v1  false：本地 shell 走自带 PTY，不经 ACP terminal）。
    public var terminal: Bool?
    public init(fs: FsCapability? = nil, terminal: Bool? = false) {
        self.fs = fs
        self.terminal = terminal
    }
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

public struct PromptCapabilities: Codable, Sendable, Equatable {
    public var image: Bool?
    public var audio: Bool?
    public var embeddedContext: Bool?
}

public struct McpCapabilities: Codable, Sendable, Equatable {
    public var http: Bool?
    public var sse: Bool?
    public var acp: Bool?
}

/// dsh 0.2 initialize 实证返回 `sessionCapabilities: { close:{}, list:{}, resume:{} }`
///（对象存在即支持，非布尔）。用 JSONValue 承载，语义化访问器判定支持性。
public struct SessionCapabilities: Codable, Sendable, Equatable {
    public var close: JSONValue?
    public var list: JSONValue?
    public var resume: JSONValue?

    public var supportsClose: Bool { close != nil }
    public var supportsList: Bool { list != nil }
    public var supportsResume: Bool { resume != nil }
}

public struct AgentCapabilities: Codable, Sendable, Equatable {
    public var loadSession: Bool?
    public var promptCapabilities: PromptCapabilities?
    public var mcpCapabilities: McpCapabilities?
    public var sessionCapabilities: SessionCapabilities?
    public init(loadSession: Bool? = nil,
                promptCapabilities: PromptCapabilities? = nil,
                mcpCapabilities: McpCapabilities? = nil,
                sessionCapabilities: SessionCapabilities? = nil) {
        self.loadSession = loadSession
        self.promptCapabilities = promptCapabilities
        self.mcpCapabilities = mcpCapabilities
        self.sessionCapabilities = sessionCapabilities
    }
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
        case protocolVersion, capabilities, serverInfo, agentInfo, agentCapabilities,
             instructions, authMethods
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        capabilities = (try? c.decodeIfPresent(AgentCapabilities.self, forKey: .capabilities))
            ?? (try? c.decodeIfPresent(AgentCapabilities.self, forKey: .agentCapabilities))
        serverInfo = try c.decodeIfPresent(ClientInfo.self, forKey: .serverInfo)
            ?? c.decode(ClientInfo.self, forKey: .agentInfo)
        instructions = try? c.decodeIfPresent(String.self, forKey: .instructions)
        authMethods = try? c.decodeIfPresent([String].self, forKey: .authMethods)
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

/// ACP 1.x 线格式：mcpServers 是**数组**（type 判别 http/sse/acp/stdio）。
/// v1 不挂外置 MCP，传空数组；保留类型以便后续扩展。
///
/// http 变体的 `headers` 与 stdio 变体的 `env` 在线格式上是**数组**（name/value
/// 条目），不是字典——dsh 的 resolveMcpConfigs 直接 `entriesToRecord(server.headers)`，
/// 缺这个字段会 TypeError 让整个 session/new 失败（实测读码：
/// dsh-acp/lib/index.js:245）。CogniTerm 的终端 MCP server 走 http，headers 传空数组。
public struct McpHeaderEntry: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct McpServerConfig: Codable, Sendable {
    public var type: String?         // "stdio" / "http" / "sse" / "acp"
    public var name: String?
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    public var url: String?
    /// http 传输的自定义头（线格式数组；不需要时也要给 `[]`）。
    public var headers: [McpHeaderEntry]?

    public init(type: String? = nil,
                name: String? = nil,
                command: String? = nil,
                args: [String]? = nil,
                env: [String: String]? = nil,
                url: String? = nil,
                headers: [McpHeaderEntry]? = nil) {
        self.type = type
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, command, args, env, url, headers
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encodeIfPresent(args, forKey: .args)
        try c.encodeIfPresent(env, forKey: .env)
        try c.encodeIfPresent(url, forKey: .url)
        // headers 用 encodeIfPresent：nil 时不出现该键（对端走默认），
        // 空数组则必须出现——dsh 对 http server 的 headers 做 for-of 遍历。
        try c.encodeIfPresent(headers, forKey: .headers)
    }
}

public struct SessionNewParams: Codable, Sendable {
    public var cwd: String
    public var mcpServers: [McpServerConfig]
    public var model: ModelSelection?
    public var reasoningEffort: String?

    public init(cwd: String,
                mcpServers: [McpServerConfig]? = nil,
                model: ModelSelection? = nil,
                reasoningEffort: String? = nil) {
        self.cwd = cwd
        self.mcpServers = mcpServers ?? []
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct SessionMode: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var description: String?
}

public struct SessionModeState: Codable, Sendable, Equatable {
    public var currentModeId: String
    public var availableModes: [SessionMode]
}

// MARK: - 会话配置项（configOptions 一族）

/// dsh-acp 广告的两个标准配置项 id（`AcpModelControl`，线格式 schema 的
/// `SessionConfigOptionCategory` 与之对应）。
///
/// 别把这两个当白名单：ACP 允许任意 `_` 前缀的扩展 id，UI 按 id 取值只用于
/// 找「要突出显示的那一个」，其余选项照样展示。
public enum SessionConfigID {
    /// 模型选择（category = "model"）。currentValue 形如
    /// `'["deepseek-official","deepseek-flash"]'` —— **JSON 数组的字符串**，
    /// 不是 provider/model 两个字段（见 dsh `modelValue()`）。
    public static let model = "model"
    /// 推理强度（category = "thought_level"）。空串表示「服务端默认」。
    public static let reasoningEffort = "reasoning_effort"
}

/// 选项集里的一个可选值。
///
/// schema 标 `required: ["value","name"]`，这里 `name` 仍取可空：dsh 之外的对端
/// 可能漏字段，缺一个展示名不该让整个选项集消失（用 `label` 取展示文本）。
public struct SessionConfigSelectOption: Codable, Sendable, Equatable {
    public var value: String
    public var name: String?
    public var description: String?

    public init(value: String, name: String? = nil, description: String? = nil) {
        self.value = value
        self.name = name
        self.description = description
    }

    /// 展示名；缺 name 或 name 为空串时回落 value（绝不返回空串）。
    public var label: String {
        if let name, !name.isEmpty { return name }
        return value
    }
}

/// 按 provider 分组的选项（dsh 的 model option 就是这一形状）。
public struct SessionConfigSelectGroup: Codable, Sendable, Equatable {
    public var group: String?
    public var name: String?
    public var options: [SessionConfigSelectOption]

    public init(group: String? = nil,
                name: String? = nil,
                options: [SessionConfigSelectOption] = []) {
        self.group = group
        self.name = name
        self.options = options
    }

    public var label: String {
        if let name, !name.isEmpty { return name }
        return group ?? ""
    }

    private enum CodingKeys: String, CodingKey { case group, name, options }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = c.lenient(String.self, forKey: .group)
        name = c.lenient(String.self, forKey: .name)
        // 组内逐项宽松：schema 对 group.options 标了 x-deserialize-skip-invalid-items，
        // 坏一项不该让整个组（连带其它好项）消失。
        options = LenientArray.decode(SessionConfigSelectOption.self,
                                      from: c.lenient([JSONValue].self, forKey: .options) ?? [])
    }
}

/// 选项集本体。schema 是 `anyOf` 的**两种同为数组**的形状：
///   Ungrouped → `[SessionConfigSelectOption]`
///   Grouped   → `[SessionConfigSelectGroup]`
/// 没有鉴别符，只能按元素形状判别（有 `group` 键即分组）。
public enum SessionConfigSelectOptions: Sendable, Equatable {
    case ungrouped([SessionConfigSelectOption])
    case grouped([SessionConfigSelectGroup])

    /// 统一成分组视图：ungrouped 包成单个匿名组，展示逻辑只写一遍。
    public var groups: [SessionConfigSelectGroup] {
        switch self {
        case .grouped(let groups): return groups
        case .ungrouped(let options): return [SessionConfigSelectGroup(options: options)]
        }
    }

    /// 展平后的全部可选值（跨组不去重，交给调用方按 value 查）。
    public var allOptions: [SessionConfigSelectOption] {
        groups.flatMap(\.options)
    }

    public func option(forValue value: String) -> SessionConfigSelectOption? {
        allOptions.first { $0.value == value }
    }
}

extension SessionConfigSelectOptions: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode([JSONValue].self)
        if let first = raw.first, first.objectValue?["group"] != nil {
            self = .grouped(LenientArray.decode(SessionConfigSelectGroup.self, from: raw))
        } else {
            self = .ungrouped(LenientArray.decode(SessionConfigSelectOption.self, from: raw))
        }
    }
}

/// 一条会话配置项。线格式是 `oneOf` + `discriminator: type`：
///   select  → `{id, name, type:"select", currentValue: String, options: ...}`
///   boolean → `{id, name, type:"boolean", currentValue: Bool}`
///
/// 只解不编：这一族字段在 schema 里标的是 `x-side: agent`，方向单一（服务端→客户端），
/// 客户端永远只读。定义 Encodable 只会带来"能编但编不出服务端形状"的错觉。
public struct SessionConfigOption: Decodable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case select(currentValue: String, options: SessionConfigSelectOptions)
        case boolean(currentValue: Bool)
        /// 未识别的 type（ACP 允许扩展）。仍保留 id/name/category，但不假定取值形状。
        case unknown(type: String?)
    }

    public var id: String
    public var name: String?
    public var description: String?
    /// UX 提示用，不得作为正确性依据（"model" / "thought_level" / ...）。
    public var category: String?
    public var kind: Kind

    public var isSelect: Bool {
        if case .select = kind { return true }
        return false
    }

    /// select 分支的 currentValue（JSON 字符串，模型项即 `'["provider","model"]'`）。
    public var currentSelectValue: String? {
        if case .select(let value, _) = kind { return value }
        return nil
    }

    /// select 分支的选项集。
    public var selectOptions: SessionConfigSelectOptions? {
        if case .select(_, let options) = kind { return options }
        return nil
    }

    /// 展示名；缺 name 时回落 id。
    public var label: String {
        if let name, !name.isEmpty { return name }
        return id
    }

    /// 当前值对应的展示名；查不到就原样显示值（空串给个可读替代）。
    public var currentLabel: String {
        switch kind {
        case .select(let value, let options):
            if let option = options.option(forValue: value) { return option.label }
            return value.isEmpty ? "服务端默认" : value
        case .boolean(let value):
            return value ? "开" : "关"
        case .unknown:
            return "（未知类型）"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, category, type, currentValue, options
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // id 是唯一硬要求：没有 id 的选项在 UI 里无法表意，交给上层丢弃。
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, forKey: .name)
        description = c.lenient(String.self, forKey: .description)
        category = c.lenient(String.self, forKey: .category)
        let type = c.lenient(String.self, forKey: .type)
        switch type {
        case "select"?:
            kind = .select(currentValue: c.lenient(String.self, forKey: .currentValue) ?? "",
                           options: c.lenient(SessionConfigSelectOptions.self, forKey: .options) ?? .ungrouped([]))
        case "boolean"?:
            kind = .boolean(currentValue: c.lenient(Bool.self, forKey: .currentValue) ?? false)
        default:
            kind = .unknown(type: type)
        }
    }
}

/// `session/set_config_option` 的请求参数。
///
/// schema 是 `anyOf` 两变体：`value_id`（`type` 缺省，默认分支）与
/// `type: "boolean"`。**dsh 0.2 目前只实现 select 形状**：`AcpModelControl.set`
/// 先判 `typeof value !== "string"` 就抛 "requires a select value"，
/// 所以实际只会走 `value_id` 变体；boolean 分支按 schema 保留以对齐线格式。
public struct SetSessionConfigOptionParams: Codable, Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        /// `value_id` 变体：单字符串，wire 上**不出现** `type` 字段。
        case id(String)
        /// `boolean` 变体：`type: "boolean"` + 布尔 value。
        case boolean(Bool)
    }

    public var sessionId: String
    public var configId: String
    public var value: Value

    public init(sessionId: String, configId: String, value: Value) {
        self.sessionId = sessionId
        self.configId = configId
        self.value = value
    }

    /// 便捷：select 形状（dsh 实际唯一支持的分支）。
    public init(sessionId: String, configId: String, value: String) {
        self.init(sessionId: sessionId, configId: configId, value: .id(value))
    }

    private enum CodingKeys: String, CodingKey { case sessionId, configId, value, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        configId = try c.decode(String.self, forKey: .configId)
        if c.lenient(String.self, forKey: .type) == "boolean",
           let flag = c.lenient(Bool.self, forKey: .value) {
            value = .boolean(flag)
        } else {
            value = .id(try c.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(configId, forKey: .configId)
        switch value {
        case .id(let raw):
            // type 缺省即 value_id 变体；显式写 type 反而可能与 schema 判别冲突。
            try c.encode(raw, forKey: .value)
        case .boolean(let flag):
            try c.encode("boolean", forKey: .type)
            try c.encode(flag, forKey: .value)
        }
    }
}

/// 一份完整的选项集响应体。`session/set_config_option` 与 `session/resume`
/// 的响应载荷都是这一个形状（前者 schema 标 required，后者没有）。
public struct SessionConfigOptionsResult: Decodable, Sendable, Equatable {
    public var configOptions: [SessionConfigOption]

    public init(configOptions: [SessionConfigOption]) {
        self.configOptions = configOptions
    }

    private enum CodingKeys: String, CodingKey { case configOptions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        configOptions = LenientArray.decode(SessionConfigOption.self,
                                            from: c.lenient([JSONValue].self, forKey: .configOptions) ?? [])
    }

    /// 按 id 取一项。
    public func option(id: String) -> SessionConfigOption? {
        configOptions.first { $0.id == id }
    }

    /// 按 category 取第一项（UX 语义查找，判空即可）。
    public func option(category: String) -> SessionConfigOption? {
        configOptions.first { $0.category == category }
    }
}

public struct SessionNewResult: Decodable, Sendable {
    public var sessionId: String?
    public var modes: SessionModeState?
    /// 初始会话配置项；dsh 0.2 的 session/new 实际**不返回 modes**，只返回它。
    public var configOptions: [SessionConfigOption]?

    private enum CodingKeys: String, CodingKey { case sessionId, modes, configOptions }

    public init(sessionId: String? = nil,
                modes: SessionModeState? = nil,
                configOptions: [SessionConfigOption]? = nil) {
        self.sessionId = sessionId
        self.modes = modes
        self.configOptions = configOptions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = c.lenient(String.self, forKey: .sessionId)
        modes = c.lenient(SessionModeState.self, forKey: .modes)
        if let raw = c.lenient([JSONValue].self, forKey: .configOptions) {
            configOptions = LenientArray.decode(SessionConfigOption.self, from: raw)
        } else {
            configOptions = nil
        }
    }
}

// MARK: - 宽松解码助手

/// 逐元素解码，**坏项丢弃、好项保留**。
///
/// 这不是可选优化，是 schema 的明确要求：`configOptions` 一族字段都标了
/// `x-deserialize-skip-invalid-items`。一条坏选项让整个数组解码失败，UI 就会
/// 静默失去模型选择器——正是本项目踩过的那类"静默失效"（资产在不在 ≠ 能不能取到）。
private enum LenientArray {
    static func decode<T: Decodable>(_ type: T.Type, from raw: [JSONValue]) -> [T] {
        raw.compactMap { element in
            guard let data = try? element.reencoded(using: JSONEncoder.acp) else { return nil }
            return try? JSONDecoder.acp.decode(T.self, from: data)
        }
    }
}

private extension KeyedDecodingContainer {
    /// 宽容解码：字段缺失**或类型不符**都返回 nil，不抛错。
    ///
    /// 用 `try?` 而不是 `decodeIfPresent` 的直接原因：后者只在"键不存在"时给 nil，
    /// 键存在但类型不对（如 `name` 是数字）会抛错并连带丢掉整条记录。
    func lenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
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

/// session/close 在 ACP 1.x 是 request（响应体为空对象），不是 notification。
public struct CloseParams: Codable, Sendable {
    public var sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
}

public struct SetModeParams: Codable, Sendable {
    public var sessionId: String
    public var modeId: String
    public init(sessionId: String, modeId: String) {
        self.sessionId = sessionId
        self.modeId = modeId
    }
}

// MARK: - list / resume

public struct SessionInfo: Codable, Sendable, Identifiable {
    public var sessionId: String
    public var cwd: String?
    public var title: String?
    /// ISO 8601（dsh 0.2 实际只回 sessionId/cwd；schema 另有 title/updatedAt）。
    public var updatedAt: String?
    public var additionalDirectories: [String]?
    public var id: String { sessionId }
}

public struct SessionListParams: Codable, Sendable {
    public var cwd: String?
    public var cursor: String?
    public init(cwd: String? = nil, cursor: String? = nil) {
        self.cwd = cwd
        self.cursor = cursor
    }
}

public struct SessionListResult: Codable, Sendable {
    public var sessions: [SessionInfo]
    /// 游标分页：nil 表示没有更多页。
    public var nextCursor: String?
}

public struct SessionResumeParams: Codable, Sendable {
    public var sessionId: String
    public var cwd: String?
    public var mcpServers: [McpServerConfig]
    public init(sessionId: String,
                cwd: String? = nil,
                mcpServers: [McpServerConfig]? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.mcpServers = mcpServers ?? []
    }
}

// MARK: - request_permission（server → client）

/// 线格式对齐 ACP ToolCallUpdate（dsh-acp/lib/index.js: `toolCall: { toolCallId }`
/// 只带 ID；命令明细来自先行的 tool_call 事件，见 ToolCallTracker）。
public struct ToolCall: Codable, Sendable {
    public var toolCallId: String?
    /// 兼容更早期草案的 id 字段。
    public var id: String?
    /// dsh 0.2：title = 工具名（如 "bash"）；命令文本在 rawInput。
    public var title: String?
    /// UNSTABLE：程序化工具名。
    public var name: String?
    public var kind: String?            // "execute" / "view" / "other" ...
    public var status: String?
    public var rawInput: JSONValue?
    public var locations: [ToolCallLocation]?

    /// 归一化主键：toolCallId 优先，退回 id。
    public var primaryId: String? { toolCallId ?? id }

    public init(toolCallId: String? = nil,
                id: String? = nil,
                title: String? = nil,
                name: String? = nil,
                kind: String? = nil,
                status: String? = nil,
                rawInput: JSONValue? = nil,
                locations: [ToolCallLocation]? = nil) {
        self.toolCallId = toolCallId
        self.id = id
        self.title = title
        self.name = name
        self.kind = kind
        self.status = status
        self.rawInput = rawInput
        self.locations = locations
    }
}

public struct ToolCallLocation: Codable, Sendable, Equatable {
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

    public init(sessionId: String, toolCall: ToolCall, options: [PermissionOption] = []) {
        self.sessionId = sessionId
        self.toolCall = toolCall
        self.options = options
    }
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
/// - user_message_chunk / agent_message_chunk / agent_thought_chunk: messageId + content（单个块）
/// - tool_call: toolCallId + title + kind + status + rawInput + locations
/// - tool_call_update: toolCallId + status（+ content 结果块数组）
/// - plan / plan_update: entries[{content,status,priority}]
/// - usage_update: used + size
/// - current_mode_update: currentModeId
/// - config_option_update: configOptions（完整选项集，服务端在拓扑变化后广播）
/// - available_commands_update / session_info_update / compaction_*: v1 忽略
public struct SessionUpdateEvent: Decodable, Sendable {
    public enum Kind {
        public static let userMessageChunk = "user_message_chunk"
        public static let agentMessageChunk = "agent_message_chunk"
        public static let agentThoughtChunk = "agent_thought_chunk"
        public static let toolCall = "tool_call"
        public static let toolCallUpdate = "tool_call_update"
        public static let plan = "plan"
        public static let planUpdate = "plan_update"
        public static let usageUpdate = "usage_update"
        public static let currentModeUpdate = "current_mode_update"
        public static let availableCommandsUpdate = "available_commands_update"
        public static let configOptionUpdate = "config_option_update"
        public static let sessionInfoUpdate = "session_info_update"
        public static let compactionUpdate = "compaction_update"
        public static let compactionSummaryChunk = "compaction_summary_chunk"
    }

    public var sessionUpdate: String
    public var messageId: String?
    public var toolCallId: String?
    public var title: String?
    public var name: String?
    public var kind: String?
    public var status: String?
    /// agent chunk 为单块 {type,text}；tool_call_update 为 ToolCallContent 数组。
    /// 统一按 JSONValue 收，再经 textContent / resultText 取用。
    public var content: JSONValue?
    public var rawInput: JSONValue?
    public var locations: [ToolCallLocation]?
    /// plan / plan_update 的条目数组。
    public var entries: JSONValue?
    /// usage_update：已用 token 与上下文窗口。
    public var used: Int64?
    public var size: Int64?
    /// current_mode_update。
    public var currentModeId: String?
    /// config_option_update 的选项集。**按 JSONValue 收**：这一条通知与
    /// agent_message_chunk 共用同一个信封，若把选项集强类型化解码失败，
    /// 丢的是整条通知而不是一个选项（会把该轮的正文一起吞掉）。
    /// 语义化视图走 `sessionConfigOptions`。
    public var configOptions: JSONValue?

    /// config_option_update 的强类型视图（逐项宽松，坏项丢弃）。
    public var sessionConfigOptions: [SessionConfigOption]? {
        configOptions?.arrayValue.map {
            LenientArray.decode(SessionConfigOption.self, from: $0)
        }
    }

    /// agent_message_chunk / user_message_chunk 的文本块。
    public var textContent: String? {
        content?.objectValue?["text"]?.stringValue
    }

    /// tool_call_update 的结果文本：content 是 [{type:"content",content:{type:"text",text}}]。
    public var resultText: String? {
        guard let blocks = content?.arrayValue else { return nil }
        let texts = blocks.compactMap { block -> String? in
            guard let obj = block.objectValue, obj["type"]?.stringValue == "content" else { return nil }
            return obj["content"]?.objectValue?["text"]?.stringValue
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    /// plan 条目归一化。
    public var planEntries: [PlanEntry]? {
        guard let array = entries?.arrayValue else { return nil }
        let entries = array.compactMap { value -> PlanEntry? in
            guard let obj = value.objectValue,
                  let content = obj["content"]?.stringValue else { return nil }
            return PlanEntry(content: content,
                             status: obj["status"]?.stringValue ?? "pending",
                             priority: obj["priority"]?.stringValue)
        }
        return entries.isEmpty ? nil : entries
    }
}

public struct PlanEntry: Sendable, Equatable {
    public var content: String
    public var status: String
    public var priority: String?
    public init(content: String, status: String = "pending", priority: String? = nil) {
        self.content = content
        self.status = status
        self.priority = priority
    }
}

// MARK: - fs/readTextFile（server → client）

public struct FsReadTextFileParams: Codable, Sendable {
    public var sessionId: String?
    public var path: String
    /// 1-based 起始行；nil = 从头读。
    public var line: Int?
    /// 最多读取行数；nil = 到文件尾。
    public var limit: Int?
}

public struct FsReadTextFileResult: Codable, Sendable {
    public var content: String
}

/// 无载荷 ACK（session/close、session/set_mode、session/resume 等的应答体）。
public struct AcpAck: Codable, Sendable {
    public init() {}
}
