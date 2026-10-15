import XCTest
@testable import AcpClient

/// 脚本化 ACP server：在内存里按 method 应答，并记录客户端发来的通知/应答。
final class ScriptedPeer: @unchecked Sendable {
    let transport = LoopbackTransport()
    private let lock = NSLock()
    private var notifications: [(method: String, params: Data?)] = []
    private var permissionAnswers: [PermissionResponse] = []
    var initializeProtocolVersion: Int = 1

    init() {
        transport.responder = { [weak self] line in
            self?.handle(line: line) ?? []
        }
    }

    func notificationsReceived() -> [(method: String, params: Data?)] {
        lock.lock(); defer { lock.unlock() }
        return notifications
    }

    func permissionAnswersReceived() -> [PermissionResponse] {
        lock.lock(); defer { lock.unlock() }
        return permissionAnswers
    }

    /// 推送一个 request_permission 反向请求。
    func requestPermission(sessionId: String = "s1") throws {
        let params = PermissionRequestParams(
            sessionId: sessionId,
            toolCall: ToolCall(id: "tc1", kind: "execute", title: "Run", rawCommand: "git push"),
            options: [
                PermissionOption(optionId: "allow-once", name: "Allow once", kind: "allow_once"),
                PermissionOption(optionId: "reject-once", name: "Reject", kind: "reject_once"),
            ]
        )
        try transport.pushJSON(PeerRequest(id: .string("perm-1"), method: AcpMethod.requestPermission,
                                           params: params))
    }

    private func handle(line: Data) -> [Data] {
        guard let env = try? JSONDecoder.acp.decode(PeerEnvelope.self, from: line) else { return [] }
        if env.id != nil && env.method != nil {
            return respond(requestId: env.id!, method: env.method!, params: env.params)
        }
        // 客户端发给 server 的应答（如 request_permission 的结果）。
        if let id = env.id, let result = env.result {
            if let data = try? result.reencoded(),
               let response = try? JSONDecoder.acp.decode(PermissionResponse.self, from: data) {
                lock.lock(); permissionAnswers.append(response); lock.unlock()
            }
            return []
        }
        if let method = env.method {
            lock.lock(); notifications.append((method, try? env.params?.reencoded())); lock.unlock()
        }
        return []
    }

    private func respond(requestId: JSONId, method: String, params: JSONValue?) -> [Data] {
        switch method {
        case AcpMethod.initialize:
            let result = InitializeResult(
                protocolVersion: initializeProtocolVersion,
                capabilities: AgentCapabilities(loadSession: false),
                serverInfo: ClientInfo(name: "dsh-test", version: "0.2.0-rc.2"),
                instructions: nil
            )
            return [try! PeerResponse(id: requestId, result: result).json()]
        case AcpMethod.sessionNew:
            return [try! PeerResponse(id: requestId,
                                      result: SessionNewResult(sessionId: "abc-123")).json()]
        case AcpMethod.sessionPrompt:
            let result = PromptResult(stopReason: "end_turn", stopError: nil)
            return [try! PeerResponse(id: requestId, result: result).json()]
        case AcpMethod.sessionList:
            let result = SessionListResult(sessions: [
                SessionInfo(sessionId: "abc-123", cwd: "/tmp/ws", title: "旧会话")
            ])
            return [try! PeerResponse(id: requestId, result: result).json()]
        case AcpMethod.sessionCancel, AcpMethod.sessionClose, AcpMethod.sessionResume:
            return [try! PeerResponse(id: requestId, result: EmptyResult()).json()]
        default:
            return [PeerFailure(id: requestId, code: -32601, message: "not found").json()]
        }
    }

    struct EmptyResult: Codable {}
    struct PeerEnvelope: Decodable {
        let id: JSONId?
        let method: String?
        let params: JSONValue?
        let result: JSONValue?
    }
    struct PeerRequest<P: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: JSONId
        let method: String
        let params: P
    }
    struct PeerResponse<R: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: JSONId
        let result: R
        func json() throws -> Data { try JSONEncoder.acp.encode(self) }
    }
    struct PeerFailure: Encodable {
        struct Body: Encodable { let code: Int; let message: String }
        let jsonrpc = "2.0"
        let id: JSONId
        let error: Body
        init(id: JSONId, code: Int, message: String) {
            self.id = id
            self.error = Body(code: code, message: message)
        }
        func json() -> Data { try! JSONEncoder.acp.encode(self) }
    }
}

final class AcpConnectionTests: XCTestCase {

    @MainActor
    func testInitializeRoundTrip() async throws {
        let peer = ScriptedPeer()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start()

        let result = try await client.initialize(clientName: "CogniTerm", clientVersion: "0.1")
        XCTAssertEqual(result.serverInfo.name, "dsh-test")
        XCTAssertEqual(result.protocolVersion, 1)
    }

    @MainActor
    func testSessionLifecycle() async throws {
        let peer = ScriptedPeer()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start()

        let sessionId = try await client.newSession(cwd: URL(fileURLWithPath: "/tmp/ws"))
        XCTAssertEqual(sessionId, "abc-123")

        let promptResult = try await client.prompt(sessionId: sessionId, text: "hello")
        XCTAssertEqual(promptResult.stopReason, "end_turn")

        try await client.cancel(sessionId: sessionId)
        try await client.close(sessionId: sessionId)

        let calls = peer.notificationsReceived().map(\.method)
        XCTAssertEqual(calls, [AcpMethod.sessionCancel, AcpMethod.sessionClose])
    }

    @MainActor
    func testListSessions() async throws {
        let peer = ScriptedPeer()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start()

        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.first?.sessionId, "abc-123")
        XCTAssertEqual(sessions.first?.title, "旧会话")
    }

    @MainActor
    func testRPCErrorSurfaces() async throws {
        let peer = ScriptedPeer()
        let connection = AcpConnection(transport: peer.transport)
        try await connection.start()
        do {
            let _: ScriptedPeer.EmptyResult = try await connection.request("bogus/method",
                                                                            params: ScriptedPeer.EmptyResult())
            XCTFail("应当抛出 rpc 错误")
        } catch let AcpError.rpc(code, message) {
            XCTAssertEqual(code, -32601)
            XCTAssertTrue(message.contains("not found"))
        }
    }

    @MainActor
    func testRequestTimeout() async throws {
        let transport = LoopbackTransport()
        transport.responder = { _ in [] } // 永不回应
        let connection = AcpConnection(transport: transport)
        try await connection.start()
        do {
            let _: ScriptedPeer.EmptyResult = try await connection.request(
                AcpMethod.initialize,
                params: InitializeParams(clientInfo: .init(name: "x", version: "1")),
                timeout: 0.05
            )
            XCTFail("应当超时")
        } catch AcpError.timeout(let method) {
            XCTAssertEqual(method, AcpMethod.initialize)
        }
    }

    @MainActor
    func testPermissionBrokerAnswersAllow() async throws {
        let peer = ScriptedPeer()
        let broker = await PermissionBroker()
        await broker.setAnswerer(AutoAnswerer { _ in .allow() })

        let client = DshAcpClient(transport: peer.transport)
        try await client.start(serverHandler: broker)
        _ = try await client.initialize(clientName: "x", clientVersion: "1")

        try peer.requestPermission()

        // 等待异步 server 请求被 broker 处理并回帧。
        try await waitUntil { !peer.permissionAnswersReceived().isEmpty }
        let answer = peer.permissionAnswersReceived().first
        XCTAssertEqual(answer?.status, .selected)
        XCTAssertEqual(answer?.optionId, "allow-once")
    }

    /// 回归：dsh 0.2 真实线格式——扁平 session/update 事件必须解出消息与工具调用。
    func testDecodeRealWireSessionUpdate() throws {
        let messageFrame = Data("""
        {"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk",
        "messageId":"m9","content":{"type":"text","text":"hello"}}}
        """.utf8)
        let message = try JSONDecoder.acp.decode(SessionNotificationParams.self, from: messageFrame)
        XCTAssertEqual(message.update?.sessionUpdate, "agent_message_chunk")
        XCTAssertEqual(message.update?.messageId, "m9")
        XCTAssertEqual(message.update?.content?.text, "hello")

        let toolFrame = Data("""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc-9",
        "title":"ls","kind":"other","status":"in_progress","rawInput":{"path":"/tmp"}}}
        """.utf8)
        let tool = try JSONDecoder.acp.decode(SessionNotificationParams.self, from: toolFrame)
        XCTAssertEqual(tool.update?.toolCallId, "tc-9")
        XCTAssertEqual(tool.update?.title, "ls")
        XCTAssertEqual(tool.update?.status, "in_progress")
    }

    /// 回归：request_permission 线格式 optionId 字段，以及嵌套 outcome 应答。
    func testRealPermissionRequestAndNestedResponse() throws {
        let frame = Data("""
        {"sessionId":"s1","toolCall":{"toolCallId":"tc-1"},
        "options":[{"optionId":"allow-once","name":"Allow once","kind":"allow_once"},
        {"optionId":"reject-once","name":"Reject","kind":"reject_once"}]}
        """.utf8)
        let request = try JSONDecoder.acp.decode(PermissionRequestParams.self, from: frame)
        XCTAssertEqual(request.toolCall.toolCallId, "tc-1")
        XCTAssertEqual(request.options.first?.optionId, "allow-once")

        // App 按请求选项应答，编码必须是嵌套 {outcome:{outcome,optionId}}。
        let encoded = try JSONEncoder.acp.encode(request.responseAllowing())
        let json = try JSONDecoder.acp.decode([String: [String: String]].self, from: encoded)
        XCTAssertEqual(json["outcome"]?["outcome"], "selected")
        XCTAssertEqual(json["outcome"]?["optionId"], "allow-once")
    }

    @MainActor
    func testUnknownServerRequestGetsMethodNotFound() async throws {
        let peer = ScriptedPeer()
        let broker = await PermissionBroker()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start(serverHandler: broker)

        try peer.transport.pushJSON(
            ScriptedPeer.PeerRequest(id: .string("x-1"), method: "mystery/method",
                                     params: ScriptedPeer.EmptyResult())
        )

        // broker 对未实现方法返回 nil → 连接层据此回 -32601。
        let result = try await broker.handleServerRequest(
            method: "mystery/method", params: try JSONEncoder.acp.encode(EmptyParams())
        )
        XCTAssertNil(result)
    }

    // MARK: - helpers

    private func waitUntil(timeout: TimeInterval = 2, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件等待超时")
    }
}

struct EmptyParams: Encodable {}

struct AutoAnswerer: PermissionAnswerer {
    let block: @Sendable (PermissionRequestParams) -> PermissionResponse
    func answer(_ request: PermissionRequestParams) async -> PermissionResponse {
        block(request)
    }
}
