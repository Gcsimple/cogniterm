import XCTest
@testable import AcpClient

/// 脚本化 ACP server：在内存里按 method 应答，并记录客户端发来的通知/应答。
final class ScriptedPeer: @unchecked Sendable {
    let transport = LoopbackTransport()
    private let lock = NSLock()
    private var notifications: [(method: String, params: Data?)] = []
    private var permissionAnswers: [PermissionResponse] = []
    private var setConfigRequests: [JSONValue] = []
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

    /// session/set_config_option 收到的原始 params（断言线格式用）。
    func setConfigRequestsReceived() -> [JSONValue] {
        lock.lock(); defer { lock.unlock() }
        return setConfigRequests
    }

    /// 原始 JSON 应答。夹具必须是**字面量线格式**，不能经由我们自己的可编码类型——
    /// 用自家类型造夹具只能证明自洽，证明不了读得懂对端。id 按 JSON-RPC 原样回。
    func rawResponse(id: JSONId, result: [String: Any]) -> Data {
        let idValue: Any
        switch id {
        case .int(let value): idValue = value
        case .string(let value): idValue = value
        }
        // 测试夹具，结构恒定。
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": idValue, "result": result])
    }

    /// 推送一个 request_permission 反向请求（dsh 0.2 实证：只带 toolCallId）。
    func requestPermission(sessionId: String = "s1") throws {
        let params = PermissionRequestParams(
            sessionId: sessionId,
            toolCall: ToolCall(toolCallId: "tc1"),
            options: [
                PermissionOption(optionId: "allow-once", name: "Allow once", kind: "allow_once"),
                PermissionOption(optionId: "reject-once", name: "Reject", kind: "reject_once"),
            ]
        )
        try transport.pushJSON(PeerRequest(id: .string("perm-1"), method: AcpMethod.requestPermission,
                                           params: params))
    }

    /// 推送 dsh 0.2 实证的 tool_call 事件：title=工具名，命令在 rawInput.command。
    func pushToolCall(toolCallId: String = "tc1", command: String = "rm -rf build/") throws {
        let frame: [String: Any] = [
            "jsonrpc": "2.0",
            "method": AcpMethod.sessionUpdate,
            "params": [
                "sessionId": "s1",
                "update": [
                    "sessionUpdate": "tool_call",
                    "toolCallId": toolCallId,
                    "title": "bash",
                    "kind": "other",
                    "status": "in_progress",
                    "rawInput": ["command": command, "description": "clean build"],
                ],
            ],
        ]
        transport.push(try JSONSerialization.data(withJSONObject: frame))
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
            // 字面量线格式（SessionNewResult 只解不编：这一族字段是 x-side: agent 单向）。
            return [rawResponse(id: requestId, result: ["sessionId": "abc-123"])]
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
        case AcpMethod.sessionSetConfigOption:
            lock.lock(); setConfigRequests.append(params ?? .null); lock.unlock()
            // dsh 的失败语义：未知 configId → invalid_params（不静默接受）。
            guard params?.objectValue?["configId"]?.stringValue == SessionConfigID.model else {
                return [PeerFailure(id: requestId,
                                    code: -32602,
                                    message: "unknown session config option").json()]
            }
            let flash = "[\"deepseek-official\",\"deepseek-flash\"]"
            let pro = "[\"deepseek-official\",\"deepseek-v4-pro\"]"
            let groups: [[String: Any]] = [[
                "group": "deepseek-official",
                "name": "DeepSeek",
                "options": [
                    ["value": flash, "name": "DeepSeek-V4.1-Flash"],
                    ["value": pro, "name": "DeepSeek-V4-Pro"],
                ] as [[String: Any]],
            ]]
            // 服务端以**整份状态**回答（dsh AcpModelControl.set 返回的就是 options 全量）。
            return [rawResponse(id: requestId, result: [
                "configOptions": [[
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": pro,
                    "options": groups,
                ] as [String: Any]],
            ])]
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

        let sessionId = try await client.newSessionID(cwd: URL(fileURLWithPath: "/tmp/ws"))
        XCTAssertEqual(sessionId, "abc-123")

        let promptResult = try await client.prompt(sessionId: sessionId, text: "hello")
        XCTAssertEqual(promptResult.stopReason, "end_turn")

        try await client.cancel(sessionId: sessionId)
        // ACP 1.x：session/close 是 request（空响应体），不再落在通知流里。
        try await client.close(sessionId: sessionId)

        let calls = peer.notificationsReceived().map(\.method)
        XCTAssertEqual(calls, [AcpMethod.sessionCancel])
    }

    @MainActor
    func testListSessions() async throws {
        let peer = ScriptedPeer()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start()

        let result = try await client.listSessions(cwd: URL(fileURLWithPath: "/tmp/ws"))
        XCTAssertEqual(result.sessions.first?.sessionId, "abc-123")
        XCTAssertEqual(result.sessions.first?.title, "旧会话")
        XCTAssertNil(result.nextCursor)
    }

    /// 会话内改配置项：请求走 value_id 变体（**不带 type**），响应整份替换。
    @MainActor
    func testSetConfigOptionSendsValueIDVariantAndReturnsFullState() async throws {
        let peer = ScriptedPeer()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start()

        let pro = "[\"deepseek-official\",\"deepseek-v4-pro\"]"
        let options = try await client.setConfigOption(sessionId: "abc-123",
                                                      configId: SessionConfigID.model,
                                                      value: pro)

        // 服务端返回的是全量状态，客户端据此整体替换（不做增量合并）。
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].id, SessionConfigID.model)
        XCTAssertEqual(options[0].currentSelectValue, pro)
        XCTAssertEqual(options[0].currentLabel, "DeepSeek-V4-Pro")
        XCTAssertEqual(options[0].selectOptions?.allOptions.count, 2)

        let sent = try XCTUnwrap(peer.setConfigRequestsReceived().first?.objectValue)
        XCTAssertEqual(sent["sessionId"]?.stringValue, "abc-123")
        XCTAssertEqual(sent["configId"]?.stringValue, SessionConfigID.model)
        XCTAssertEqual(sent["value"]?.stringValue, pro)
        XCTAssertNil(sent["type"], "value_id 变体不得携带 type 字段")
    }

    /// 服务端拒绝（未知 configId）必须冒泡成 rpc 错误，不能静默成功。
    @MainActor
    func testSetConfigOptionSurfacesServerRejection() async throws {
        let peer = ScriptedPeer()
        let client = DshAcpClient(transport: peer.transport)
        try await client.start()
        do {
            _ = try await client.setConfigOption(sessionId: "abc-123",
                                                 configId: "nope",
                                                 value: "x")
            XCTFail("未知配置项应当抛错")
        } catch let AcpError.rpc(code, message) {
            XCTAssertEqual(code, -32602)
            XCTAssertTrue(message.contains("unknown session config option"))
        }
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
        XCTAssertEqual(message.update?.textContent, "hello")

        let toolFrame = Data("""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call","toolCallId":"tc-9",
        "title":"bash","kind":"other","status":"in_progress","rawInput":{"command":"ls -la","description":"list"}}}
        """.utf8)
        let tool = try JSONDecoder.acp.decode(SessionNotificationParams.self, from: toolFrame)
        XCTAssertEqual(tool.update?.toolCallId, "tc-9")
        XCTAssertEqual(tool.update?.title, "bash")
        XCTAssertEqual(tool.update?.status, "in_progress")
    }

    /// 回归：usage_update（used/size）与 plan（entries）事件的解码。
    func testDecodeUsageAndPlanUpdates() throws {
        let usageFrame = Data("""
        {"sessionId":"s1","update":{"sessionUpdate":"usage_update","used":1234,"size":128000}}
        """.utf8)
        let usage = try JSONDecoder.acp.decode(SessionNotificationParams.self, from: usageFrame)
        XCTAssertEqual(usage.update?.used, 1234)
        XCTAssertEqual(usage.update?.size, 128000)

        let planFrame = Data("""
        {"sessionId":"s1","update":{"sessionUpdate":"plan","entries":[
        {"content":"梳理需求","status":"completed","priority":"high"},
        {"content":"实现协议层","status":"in_progress","priority":"high"}]}}
        """.utf8)
        let plan = try JSONDecoder.acp.decode(SessionNotificationParams.self, from: planFrame)
        let entries = try XCTUnwrap(plan.update?.planEntries)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].content, "梳理需求")
        XCTAssertEqual(entries[0].status, "completed")
        XCTAssertEqual(entries[1].status, "in_progress")
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

    /// 回归：tool_call_update 的 content 数组形态须解出结果文本。
    func testDecodeToolCallUpdateResultText() throws {
        let frame = Data("""
        {"sessionId":"s1","update":{"sessionUpdate":"tool_call_update","toolCallId":"tc-1",
        "status":"completed","content":[{"type":"content","content":{"type":"text","text":"done"}}]}}
        """.utf8)
        let update = try JSONDecoder.acp.decode(SessionNotificationParams.self, from: frame)
        XCTAssertEqual(update.update?.resultText, "done")
        XCTAssertEqual(update.update?.status, "completed")
    }

    /// 关联链：tool_call 事件先到（带 rawInput.command），request_permission 后到（只有 toolCallId），
    /// Tracker 必须把命令文本补给审批请求——这是 rules 模式自动放行能工作的前提。
    func testToolCallTrackerCorrelatesPermissionCommand() throws {
        let tracker = ToolCallTracker()

        let toolFrame = Data("""
        {"sessionUpdate":"tool_call","toolCallId":"tc-7","title":"bash","kind":"other",
        "status":"in_progress","rawInput":{"command":"git status","description":"check"}}
        """.utf8)
        let event = try JSONDecoder.acp.decode(SessionUpdateEvent.self, from: toolFrame)
        tracker.record(event)

        let snapshot = try XCTUnwrap(tracker.snapshot(for: "tc-7"))
        XCTAssertEqual(snapshot.title, "bash")
        XCTAssertEqual(snapshot.commandText, "git status")
        XCTAssertEqual(snapshot.displayTitle, "bash · git status")
        XCTAssertEqual(snapshot.invocation.tool, "bash")

        // 更新到达：只改状态与结果文本，不动命令文本。
        let updateFrame = Data("""
        {"sessionUpdate":"tool_call_update","toolCallId":"tc-7","status":"completed",
        "content":[{"type":"content","content":{"type":"text","text":"clean"}}]}
        """.utf8)
        tracker.record(try JSONDecoder.acp.decode(SessionUpdateEvent.self, from: updateFrame))
        let updated = try XCTUnwrap(tracker.snapshot(for: "tc-7"))
        XCTAssertEqual(updated.status, "completed")
        XCTAssertEqual(updated.resultText, "clean")
        XCTAssertEqual(updated.commandText, "git status")
    }

    /// fs/read_text_file（SDK 1.4.0 蛇形方法名）经 broker 路由到 reader。
    @MainActor
    func testBrokerRoutesSnakeCaseFsRead() async throws {
        let broker = await PermissionBroker()
        await broker.setFileSystemReader { path, line, limit in
            XCTAssertEqual(path, "/tmp/ws/a.txt")
            XCTAssertEqual(line, 2)
            XCTAssertEqual(limit, 3)
            return "b\nc\nd"
        }

        let params = Data("""
        {"sessionId":"s1","path":"/tmp/ws/a.txt","line":2,"limit":3}
        """.utf8)
        let result = try await broker.handleServerRequest(method: AcpMethod.fsReadTextFile, params: params)
        let decoded = try XCTUnwrap(result.flatMap { try? JSONDecoder.acp.decode(FsReadTextFileResult.self, from: $0) })
        XCTAssertEqual(decoded.content, "b\nc\nd")
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
