import XCTest
@testable import CogniTerm
import AcpClient

/// 终端 MCP server 回归：协议面（initialize/tools/list/tools/call）、
/// 审批门（allow/reject/timeout）、串行执行、迟到输出 relay。
///
/// 全部走**真实 HTTP**（NWListener + URLSession），不 mock 传输层——
/// 这个 server 的契约就是"dsh 的 streamable-http 客户端连得上、说得通"，
/// mock 掉传输层等于把要验证的东西验证没了。
@MainActor
final class TerminalMCPServerTests: XCTestCase {

    private var server: TerminalMCPServer!
    private var gate: FakeTerminalGate!
    private var executor: FakeTerminalExecutor!
    /// onLateOutput 收到的 (command, output)。
    private var lateOutputs: [(String, String)] = []

    override func setUp() async throws {
        // singleton：每个用例前复位到干净态（上一个用例可能留着队列/监听）。
        server = TerminalMCPServer.shared
        server.stop()
        // 测试用短时限：不必真等 55 秒验超时路径。
        server.softDeadline = 2
        server.gateTimeout = 1
        gate = FakeTerminalGate()
        executor = FakeTerminalExecutor()
        server.gate = gate
        server.executor = executor
        lateOutputs = []
        server.onLateOutput = { [weak self] command, output in
            self?.lateOutputs.append((command, output))
        }
    }

    override func tearDown() async throws {
        server.stop()
        server.onLateOutput = nil
    }

    // MARK: - 协议面

    /// initialize 回显客户端 protocolVersion（SDK 用自己支持的列表校验，
    /// 回错版本直接 handshake 失败）；广告 tools 能力与 serverInfo。
    func testInitializeEchoesProtocolVersion() async throws {
        try await startServer()
        let response = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "dsh", "version": "0.2"],
            ],
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"], "要广告 tools 能力，否则客户端不列工具")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "cogniterm-terminal")
        XCTAssertFalse((result["instructions"] as? String ?? "").isEmpty,
                       "instructions 要把终端工具的用法带进模型上下文")
    }

    /// notifications/initialized 是通知：200 空响应。
    /// ⚠️ 不能回 202——那会促使 MCP SDK 去开 SSE 流，而我们不开流。
    func testInitializedNotificationGetsEmpty200() async throws {
        try await startServer()
        let (data, http) = try await postRaw([
            "jsonrpc": "2.0", "method": "notifications/initialized",
        ])
        XCTAssertEqual(http.statusCode, 200)
        XCTAssertTrue(data.isEmpty, "通知不该有响应体，实际：\(String(decoding: data, as: UTF8.self))")
    }

    /// tools/list 广告 run_in_terminal：名字、描述、必填 command。
    func testToolsListAdvertisesRunInTerminal() async throws {
        try await startServer()
        let response = try await post([
            "jsonrpc": "2.0", "id": 2, "method": "tools/list",
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool["name"] as? String, "run_in_terminal")
        XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
        let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
        XCTAssertEqual((schema["required"] as? [String])?.first, "command")
    }

    /// ping → 空 result。
    func testPing() async throws {
        try await startServer()
        let response = try await post(["jsonrpc": "2.0", "id": 3, "method": "ping"])
        XCTAssertNotNil(response["result"])
        XCTAssertNil(response["error"])
    }

    /// 未知方法 → JSON-RPC -32601（不是 HTTP 500，也不是静默）。
    func testUnknownMethodGetsJSONRPCError() async throws {
        try await startServer()
        let response = try await post(["jsonrpc": "2.0", "id": 4, "method": "no/such/method"])
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32601)
    }

    /// 坏 JSON → -32700 parse error。
    func testGarbageBodyGetsParseError() async throws {
        try await startServer()
        let (data, http) = try await postRawData(Data("not json".utf8))
        XCTAssertEqual(http.statusCode, 200, "HTTP 层是好的，错误在 JSON-RPC 层")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700)
    }

    // MARK: - 审批门 × 执行

    /// 缺 command 参数 → isError 结果，不进审批、不进执行。
    func testToolsCallWithoutCommandIsError() async throws {
        try await startServer()
        let response = try await post(toolsCall(id: 10, arguments: [String: Any]()))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertTrue((content.first?["text"] as? String ?? "").contains("command"))
        XCTAssertNil(gate.pendingCommand, "参数都不全，不该惊动审批")
    }

    /// 拒绝 → isError 结果，**不执行**。模型收到明确拒绝语义。
    func testToolsCallRejectedNeverExecutes() async throws {
        try await startServer()
        gate.autoDecision = .reject
        let response = try await post(toolsCall(id: 11, arguments: ["command": "rm -rf /"]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let text = (try XCTUnwrap(result["content"] as? [[String: Any]]).first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("拒绝"), "拒绝语义要对模型说清楚：\(text)")
        XCTAssertTrue(executor.commands.isEmpty, "拒绝了就不能执行")
    }

    /// 允许 → 注入执行平面 → 输出作为工具结果返回。
    func testToolsCallAllowedRunsAndReturnsOutput() async throws {
        try await startServer()
        gate.autoDecision = .allow
        let response = try await post(toolsCall(id: 12, arguments: ["command": "echo hi"]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let text = (try XCTUnwrap(result["content"] as? [[String: Any]]).first?["text"] as? String) ?? ""
        XCTAssertEqual(text, "fake output for echo hi")
        XCTAssertEqual(executor.commands, ["echo hi"])
    }

    /// 审批超时 → 取消门 + isError 结果（fail-closed）。
    func testGateTimeoutCancelsAndFails() async throws {
        try await startServer()
        // gate 不自动应答（autoDecision = nil）。
        let response = try await post(toolsCall(id: 13, arguments: ["command": "sleep 999"]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(gate.cancelCount, 1, "超时必须取消挂起的审批")
        XCTAssertTrue(executor.commands.isEmpty, "没审批过就不能执行")
    }

    /// 串行：第一条没收敛前，第二条不注入（PTY 一次一条命令）。
    func testQueueSerializesCommands() async throws {
        try await startServer()
        gate.autoDecision = .allow
        executor.holdCaptures = true

        let first = Task { try await post(toolsCall(id: 20, arguments: ["command": "first"])) }
        try await waitUntil { self.executor.commands.count == 1 }
        let second = Task { try await post(toolsCall(id: 21, arguments: ["command": "second"])) }

        // 第二条在队列里等：给足轮询窗口，确认它没有抢跑。
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(self.executor.commands, ["first"], "第一条没收敛，第二条不能注入")

        self.executor.releaseCapture("first done")
        _ = try await first.value
        try await waitUntil { self.executor.commands.count == 2 }
        executor.releaseCapture("second done")
        let secondResponse = try await second.value
        let result = try XCTUnwrap(secondResponse["result"] as? [String: Any])
        let text = (try XCTUnwrap(result["content"] as? [[String: Any]]).first?["text"] as? String) ?? ""
        XCTAssertEqual(text, "second done")
    }

    /// 超过响应窗口才收敛：先回"仍在执行"，输出迟到后经 relay 回喂。
    func testLateOutputIsRelayed() async throws {
        try await startServer()
        gate.autoDecision = .allow
        executor.holdCaptures = true

        let response = try await post(toolsCall(id: 22, arguments: ["command": "npm run build"]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "仍在执行不是错误")
        let text = (try XCTUnwrap(result["content"] as? [[String: Any]]).first?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("未收敛") && text.contains("回喂"), "超时响应要说明状态：\(text)")

        self.executor.releaseCapture("build ok")
        try await waitUntil { !self.lateOutputs.isEmpty }
        XCTAssertEqual(self.lateOutputs.first?.0, "npm run build")
        XCTAssertEqual(self.lateOutputs.first?.1, "build ok")
    }

    // MARK: - 注册条目形状

    /// serverConfig 的线格式：type=http + url + **headers 必须是数组**。
    /// dsh 对 http server 的 headers 做 for-of 遍历，缺字段/错类型会让整个
    /// session/new 失败（failOnStartupError）——这是最容易写错又最贵的一处。
    func testServerConfigWireShape() async throws {
        try await startServer()
        let config = try XCTUnwrap(server.serverConfig)
        XCTAssertEqual(config.type, "http")
        XCTAssertEqual(config.name, "cogniterm")
        XCTAssertTrue(config.url?.hasPrefix("http://127.0.0.1:") == true)
        XCTAssertTrue(config.url?.hasSuffix("/mcp") == true)
        XCTAssertEqual(config.headers, [], "空数组也必须出现：dsh entriesToRecord 对 undefined 会炸")

        // 编码出来的 JSON 里 headers 键必须存在（nil 会被 encodeIfPresent 丢掉）。
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["headers"], "线格式上 headers 键必须在")
    }

    /// 未启动时 serverConfig 为 nil——调用方（SidecarService）据此决定不注册，
    /// 绝不能拿死端点去 session/new（failOnStartupError 会炸掉整个会话创建）。
    func testServerConfigNilWhenStopped() throws {
        XCTAssertNil(server.serverConfig)
    }

    // MARK: - helpers

    private func startServer() async throws {
        try await server.start()
        XCTAssertTrue(server.isRunning)
    }

    private func endpoint() throws -> URL {
        guard let port = server.port else { throw XCTUnwrapError.nilPort }
        return URL(string: "http://127.0.0.1:\(port)/mcp")!
    }

    private enum XCTUnwrapError: Error { case nilPort }

    private func toolsCall(id: Int, arguments: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": "tools/call",
         "params": ["name": "run_in_terminal", "arguments": arguments]]
    }

    @discardableResult
    private func post(_ object: [String: Any]) async throws -> [String: Any] {
        let (data, _) = try await postRaw(object)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// 原始 HTTP 往返：返回 (body, response)。用于通知（空体）与状态码断言。
    private func postRaw(_ object: [String: Any]) async throws -> (Data, HTTPURLResponse) {
        try await postRawData(try JSONSerialization.data(withJSONObject: object))
    }

    private func postRawData(_ body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw XCTUnwrapError.nilPort
        }
        return (data, http)
    }

    private func waitUntil(timeout: TimeInterval = 3,
                           _ predicate: @MainActor @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件等待超时")
    }
}

// MARK: - Fakes

/// 不自动决断的门（autoDecision = nil 时挂起等 decide()），
/// 或按 autoDecision 立即答复。记录取消次数。
@MainActor
private final class FakeTerminalGate: TerminalCommandGate {
    var autoDecision: TerminalCommandDecision?
    private(set) var pendingCommand: String?
    private(set) var cancelCount = 0
    private var completion: ((TerminalCommandDecision) -> Void)?

    func requestTerminalCommand(_ command: String, completion: @escaping (TerminalCommandDecision) -> Void) {
        pendingCommand = command
        self.completion = completion
        if let autoDecision {
            self.completion = nil
            pendingCommand = nil
            completion(autoDecision)
        }
    }

    func cancelTerminalCommandRequest() {
        cancelCount += 1
        completion = nil
        pendingCommand = nil
    }
}

/// 执行平面 fake：holdCaptures 挂起 onCapture（模拟长命令），
/// releaseCapture 放行并置空闲。
@MainActor
private final class FakeTerminalExecutor: TerminalCommandExecutor {
    var isTerminalReady = true
    var isCapturingCommand = false
    var holdCaptures = false
    private(set) var commands: [String] = []
    private var heldCapture: (@MainActor (String) -> Void)?

    func runCommandCaptured(_ command: String, onCapture: @escaping @MainActor (String) -> Void) {
        commands.append(command)
        if holdCaptures {
            heldCapture = onCapture
            isCapturingCommand = true
        } else {
            onCapture("fake output for \(command)")
        }
    }

    func releaseCapture(_ text: String) {
        isCapturingCommand = false
        let capture = heldCapture
        heldCapture = nil
        capture?(text)
    }
}
