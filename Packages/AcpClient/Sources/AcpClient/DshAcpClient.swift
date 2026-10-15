import Foundation

public enum AcpMethod {
    public static let initialize = "initialize"
    public static let sessionNew = "session/new"
    public static let sessionPrompt = "session/prompt"
    public static let sessionCancel = "session/cancel"
    public static let sessionClose = "session/close"
    public static let sessionList = "session/list"
    public static let sessionResume = "session/resume"
    public static let sessionUpdate = "session/update"
    public static let requestPermission = "session/request_permission"
    public static let fsReadTextFile = "fs/readTextFile"
}

/// dsh ACP 侧的高级客户端：封装握手与会话生命周期。
public final class DshAcpClient: @unchecked Sendable {
    public let connection: AcpConnection

    public init(transport: RPCTransport) {
        self.connection = AcpConnection(transport: transport)
    }

    public func start(serverHandler: ServerRequestHandler? = nil) async throws {
        try await connection.start(serverHandler: serverHandler)
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
                           mcpServers: [String: McpServerConfig]? = nil,
                           model: ModelSelection? = nil,
                           reasoningEffort: String? = nil,
                           timeout: TimeInterval? = nil) async throws -> String {
        let params = SessionNewParams(cwd: cwd.standardizedFileURL.path,
                                      mcpServers: mcpServers,
                                      model: model,
                                      reasoningEffort: reasoningEffort)
        let result: SessionNewResult = try await connection.request(AcpMethod.sessionNew,
                                                                    params: params,
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

    public func close(sessionId: String) async throws {
        try await connection.notify(AcpMethod.sessionClose, params: CloseParams(sessionId: sessionId))
    }

    public func listSessions() async throws -> [SessionInfo] {
        let result: SessionListResult = try await connection.request(AcpMethod.sessionList)
        return result.sessions
    }

    public func resume(sessionId: String,
                       cwd: URL? = nil,
                       mcpServers: [String: McpServerConfig]? = nil) async throws {
        let params = SessionResumeParams(sessionId: sessionId,
                                         cwd: cwd?.standardizedFileURL.path,
                                         mcpServers: mcpServers)
        let _: AcpAck = try await connection.request(AcpMethod.sessionResume, params: params)
    }

    /// 半关闭（stdin EOF）→ dsh 排空后有界退出。
    public func gracefulShutdown() async {
        await connection.closeWriting()
    }

    public func forceTerminate() async {
        await connection.terminate()
    }
}
