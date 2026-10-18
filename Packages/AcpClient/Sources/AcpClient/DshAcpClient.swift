import Foundation

public enum AcpMethod {
    public static let initialize = "initialize"
    public static let sessionNew = "session/new"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    /// ACP 1.x：session/close 是 request（空响应体），不是 notification。
    public static let sessionClose = "session/close"
    public static let sessionList = "session/list"
    public static let sessionResume = "session/resume"
    public static let sessionSetMode = "session/set_mode"
    /// ACP 1.x：会话内实时改配置项（dsh 0.2 用它切模型 / 推理强度）。
    public static let sessionSetConfigOption = "session/set_config_option"
    public static let sessionUpdate = "session/update"
    public static let requestPermission = "session/request_permission"
    /// ACP SDK 1.4.0 实证方法名（蛇形，非 camelCase）。
    public static let fsReadTextFile = "fs/read_text_file"
    public static let fsWriteTextFile = "fs/write_text_file"
}

/// dsh ACP 侧的高级客户端：封装握手与会话生命周期。
public final class DshAcpClient: @unchecked Sendable {
    public let connection: AcpConnection

    /// toolCallTracker 传入连接层后，session/update 会在分帧路径同步记录，
    /// 保证 request_permission 到达时命令文本已入库（否则消费者 Task 有竞态）。
    public init(transport: RPCTransport, toolCallTracker: ToolCallTracker? = nil) {
        self.connection = AcpConnection(transport: transport, toolCallTracker: toolCallTracker)
    }

    public func start(serverHandler: ServerRequestHandler? = nil) async throws {
        try await connection.start(serverHandler: serverHandler)
    }

    /// 查询 tool_call 快照。
    public func toolCallSnapshot(for toolCallId: String) async -> ToolCallSnapshot? {
        await connection.toolCallSnapshot(for: toolCallId)
    }

    @discardableResult
    public func initialize(clientName: String,
                           clientVersion: String,
                           protocolVersion: Int = 1,
                           fsReadTextFile: Bool = true,
                           timeout: TimeInterval = 30) async throws -> InitializeResult {
        let params = InitializeParams(
            protocolVersion: protocolVersion,
            clientCapabilities: ClientCapabilities(fs: FsCapability(readTextFile: fsReadTextFile)),
            clientInfo: ClientInfo(name: clientName, version: clientVersion)
        )
        return try await connection.request(AcpMethod.initialize, params: params, timeout: timeout)
    }

    public func newSession(cwd: URL,
                           mcpServers: [McpServerConfig]? = nil,
                           model: ModelSelection? = nil,
                           reasoningEffort: String? = nil,
                           timeout: TimeInterval? = nil) async throws -> SessionNewResult {
        let params = SessionNewParams(cwd: cwd.standardizedFileURL.path,
                                      mcpServers: mcpServers,
                                      model: model,
                                      reasoningEffort: reasoningEffort)
        return try await connection.request(AcpMethod.sessionNew,
                                            params: params,
                                            timeout: timeout)
    }

    /// 便捷：只要 sessionId（modes/configOptions 由调用方按需取完整结果）。
    public func newSessionID(cwd: URL,
                             mcpServers: [McpServerConfig]? = nil,
                             model: ModelSelection? = nil,
                             reasoningEffort: String? = nil,
                             timeout: TimeInterval? = nil) async throws -> String {
        let result = try await newSession(cwd: cwd,
                                          mcpServers: mcpServers,
                                          model: model,
                                          reasoningEffort: reasoningEffort,
                                          timeout: timeout)
        guard let sessionId = result.sessionId else {
            throw AcpError.decode("session/new missing sessionId")
        }
        return sessionId
    }

    /// 发送一轮 prompt。流式过程通过 `connection.notifications` 中的 `session/update` 观察。
    @discardableResult
    public func prompt(sessionId: String,
                       text: String,
                       timeout: TimeInterval? = nil) async throws -> PromptResult {
        let params = SessionPromptParams(sessionId: sessionId, prompt: [PromptBlock(text: text)])
        return try await connection.request(AcpMethod.sessionPrompt, params: params, timeout: timeout)
    }

    public func cancel(sessionId: String) async throws {
        try await connection.notify(AcpMethod.sessionCancel, params: CancelParams(sessionId: sessionId))
    }

    /// ACP 1.x：session/close 是 request，响应体为空对象。
    public func close(sessionId: String) async throws {
        let _: AcpAck = try await connection.request(AcpMethod.sessionClose,
                                                     params: CloseParams(sessionId: sessionId))
    }

    /// 切换会话模式（如 plan / default）；能力以 initialize 的 modes 为准。
    public func setMode(sessionId: String, modeId: String) async throws {
        let _: AcpAck = try await connection.request(AcpMethod.sessionSetMode,
                                                     params: SetModeParams(sessionId: sessionId, modeId: modeId))
    }

    /// 实时改一个会话配置项（dsh 0.2：`model` / `reasoning_effort`），
    /// 返回**变更后的完整选项集**——服务端以整份状态回答，客户端据此整体替换，
    /// 不做增量合并（dsh `AcpModelControl.set` 返回的就是 `options` 全量）。
    ///
    /// 生效范围是「后续轮次」：dsh 在 `session/request` 组装时读取当前 selection。
    @discardableResult
    public func setConfigOption(sessionId: String,
                                configId: String,
                                value: String,
                                timeout: TimeInterval? = nil) async throws -> [SessionConfigOption] {
        let params = SetSessionConfigOptionParams(sessionId: sessionId, configId: configId, value: value)
        let result: SessionConfigOptionsResult = try await connection.request(
            AcpMethod.sessionSetConfigOption, params: params, timeout: timeout)
        return result.configOptions
    }

    /// boolean 变体（按 schema 保留；dsh 0.2 的 `set` 只接受字符串值，会回 invalid_params）。
    @discardableResult
    public func setConfigOption(sessionId: String,
                                configId: String,
                                value: Bool,
                                timeout: TimeInterval? = nil) async throws -> [SessionConfigOption] {
        let params = SetSessionConfigOptionParams(sessionId: sessionId, configId: configId, value: .boolean(value))
        let result: SessionConfigOptionsResult = try await connection.request(
            AcpMethod.sessionSetConfigOption, params: params, timeout: timeout)
        return result.configOptions
    }

    /// 列出持久化会话（dsh 0.2：来自 $DSH_HOME/sessions，跨重启有效；
    /// cwd 过滤按物理目录同一性判定）。nextCursor 非空时还有下一页。
    public func listSessions(cwd: URL? = nil, cursor: String? = nil) async throws -> SessionListResult {
        let params = SessionListParams(cwd: cwd?.standardizedFileURL.path, cursor: cursor)
        return try await connection.request(AcpMethod.sessionList, params: params)
    }

    /// 恢复一个历史会话。dsh 0.2 的响应带 `configOptions`（恢复态模型选择的来源），
    /// 不返回 sessionId——调用方本来就知道它。
    @discardableResult
    public func resume(sessionId: String,
                       cwd: URL? = nil,
                       mcpServers: [McpServerConfig]? = nil) async throws -> SessionConfigOptionsResult {
        let params = SessionResumeParams(sessionId: sessionId,
                                         cwd: cwd?.standardizedFileURL.path,
                                         mcpServers: mcpServers)
        return try await connection.request(AcpMethod.sessionResume, params: params)
    }

    /// 半关闭（stdin EOF）→ dsh 排空后有界退出。
    public func gracefulShutdown() async {
        await connection.closeWriting()
    }

    public func forceTerminate() async {
        await connection.terminate()
    }
}
