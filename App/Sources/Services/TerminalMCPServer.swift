import Foundation
import Network
import AcpClient

// MARK: - 工具描述（模型可见面）

/// CogniTerm 终端 MCP 工具的唯一工具名。
///
/// 模型侧公开名由 dsh-mcp-client 的 `publicToolName(serverName, rawName)` 合成：
/// `mcp__cogniterm__run_in_terminal`（serverName = "cogniterm"）。
enum TerminalMCP {
    static let serverName = "cogniterm"
    static let toolName = "run_in_terminal"
    static let serverDisplayName = "cogniterm-terminal"
    static let serverVersion = "1.0.0"

    /// 工具描述（模型读它决定何时用）。写得越明确，模型越不会拿它干
    /// 不该干的事（比如用 shell 重定向绕开 fs 工具的沙箱语义）。
    static let toolDescription = """
    在用户可见的 CogniTerm 终端里执行一条 shell 命令，并把真实输出作为工具结果返回给你。 \
    命令会注入用户屏幕上的那个终端（用户看得见、可以随时 Ctrl-C），每次执行前会弹审批卡请用户确认；\
    用户拒绝时你会收到错误结果，不要改用其他方式尝试执行同一条命令。 \
    适合：运行构建/测试、git、ls/cat/grep 等 shell 工作。一次执行一条命令，多条命令会排队串行执行。 \
    文件读写请使用专门的 fs 工具，不要用 shell 重定向或 rm 绕开沙箱策略。 \
    如果命令执行或审批超过时限，你会收到"仍在执行"提示，完整输出稍后会以用户消息形式回喂给你。
    """

    /// 工具入参 schema（MCP inputSchema，JSON Schema 词汇）。
    static let inputSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "command": {
          "type": "string",
          "description": "要执行的完整 shell 命令，例如 \\"ls -la\\" 或 \\"npm test\\"。一次一条。"
        }
      },
      "required": ["command"]
    }
    """

    /// initialize 结果里的 instructions：会话级指引，dsh 会带进模型上下文。
    static let instructions = """
    你可以通过 run_in_terminal 在用户的真实终端里执行 shell 命令。\
    该工具每次调用都会请求用户审批，命令在用户可见的终端里执行，输出作为工具结果返回。\
    用户的终端是命令执行的唯一通道——没有其他执行 shell 的方式。
    """
}

// MARK: - 依赖协议（可替换，测试用 fake）

/// 终端命令审批门。实现方负责 UI / 规则 / 超时取消；fail-closed。
@MainActor
protocol TerminalCommandGate: AnyObject {
    /// 请求授权。completion 必达（allow / reject）；超时时服务端会调
    /// cancelTerminalCommandRequest()，实现方此时应 fail-closed 地了结请求。
    func requestTerminalCommand(_ command: String, completion: @escaping (TerminalCommandDecision) -> Void)
    /// 服务端放弃等待（超时）。实现方应清掉挂起的审批并以拒绝语义了结。
    func cancelTerminalCommandRequest()
}

enum TerminalCommandDecision {
    case allow
    case reject
}

/// 命令执行平面（TerminalSession）。
@MainActor
protocol TerminalCommandExecutor: AnyObject {
    /// PTY 就绪（会话已启动、视图已 attach）。
    var isTerminalReady: Bool { get }
    /// 正在捕获某条命令的输出（runState == .running）。
    var isCapturingCommand: Bool { get }
    /// 注入命令执行，收敛后回调剥净 ANSI、截断过的输出。回调必达
    /// （静默 3 秒启发式 + 5 分钟硬超时，见 TerminalSession.runCommandCaptured）。
    func runCommandCaptured(_ command: String, onCapture: @escaping @MainActor (String) -> Void)
}

// MARK: - MCP 工具结果

/// tools/call 的结果载荷（MCP CallToolResult 的 App 侧表示）。
struct McpToolResult {
    var text: String
    var isError: Bool

    static func success(_ text: String) -> McpToolResult { McpToolResult(text: text, isError: false) }
    static func failure(_ text: String) -> McpToolResult { McpToolResult(text: text, isError: true) }
}

// MARK: - JSON-RPC 线格式

/// JSON-RPC id：规范允许 string / number / null。dsh SDK 发递增数字。
enum JSONRPCID: Equatable {
    case string(String)
    case number(Int)
    case null

    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .null: return NSNull()
        }
    }

    static func parse(_ value: Any?) -> JSONRPCID? {
        switch value {
        case let s as String: return .string(s)
        case let n as Int: return .number(n)
        case let n as NSNumber: return .number(n.intValue)
        case is NSNull: return .null
        default: return nil
        }
    }
}

/// 协议面错误码（JSON-RPC 2.0）。
private enum JSONRPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

// MARK: - Server

/// App 内嵌的 MCP server（streamable-http，仅绑 127.0.0.1）。
///
/// **为什么存在**：agent 原先没有任何命令执行通道——tool-bash 被我们关掉
/// （它走 dsh 自己的沙箱，会和 App 的审批卡抢审批语义），于是 agent 的"干活"
/// 全在 dsh 沙箱里静默进行，终端是平行世界。这个 server 把执行平面缝合：
/// agent 调 `run_in_terminal` → App 弹审批卡 → 允许 → 命令注入用户可见的 PTY
/// → 输出作为工具结果回到 agent 上下文。
///
/// **审批在 App 侧而不是 dsh 侧**（实证结论，2026-10-18）：
/// dsh 的 `tools/pre-execute` 瀑布流默认返回 allow，内置只有 auto-review 和
/// claude-code hooks 会产出 ask；MCP 桥接层（dsh-mcp-client）没有任何审批逻辑。
/// 也就是说 MCP 工具在 dsh 侧**不走审批**。所以门必须设在 App 侧：
/// tools/call 到达 → 审批卡 → 允许才执行。这与「App 是执行平面所有者」的
/// 定位一致，也复用现有审批 UI。
///
/// **时限**（硬约束来自 dsh-mcp-client：toolCallTimeoutMs 默认 60s）：
/// 每条 tools/call 从入队起 55s 内必须给出响应，否则 dsh 放弃等待、
/// 模型只会看到超时错误。因此：排队/审批超时 → 错误结果；审批已过、命令
/// 已注入但没跑完 → "仍在执行"结果 + 输出收敛后经 onLateOutput 以 prompt
/// 形式回喂（与审批卡「在终端运行」出口同一语义）。
@MainActor
final class TerminalMCPServer: ObservableObject {
    static let shared = TerminalMCPServer()

    // MARK: 依赖

    weak var gate: TerminalCommandGate?
    weak var executor: TerminalCommandExecutor?
    /// 迟到的输出（超过 55s 窗口才收敛的命令）回喂给 agent 的通道。
    /// 由 MainSplitView 设置（它持有 sidecar 会话）。
    var onLateOutput: (@MainActor (String, String) -> Void)?

    // MARK: 可观测状态

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16?
    @Published private(set) var lastEvent: String = "未启动"
    /// 已处理请求数（诊断）。
    @Published private(set) var handledRequests = 0

    private var listener: NWListener?
    private var queue: [QueuedCall] = []
    private var processing = false

    /// 从入队起算的软 deadline（必须小于 dsh 的 60s 工具超时，留 5s 传输余量）。
    /// 非 private：测试用极小值验证超时路径，不必真等 55 秒。
    var softDeadline: TimeInterval = 55
    /// 审批等待上限（含在软 deadline 内）。
    var gateTimeout: TimeInterval = 50
    /// 各阶段比软 deadline 提前的量：保证"仍在执行"由 phase 3 发出，
    /// 不被任何其他路径截胡（响应语义确定，避免竞态）。
    private let deadlineMargin: TimeInterval = 1
    /// 终端空闲轮询间隔。
    private let idlePollInterval: Duration = .milliseconds(500)

    private init() {}

    // MARK: 生命周期

    /// session/new 注册用的 mcpServers 条目；server 未启动时返回 nil
    /// （调用方此时不应传 mcpServers——failOnStartupError 会让整个会话创建失败）。
    var serverConfig: McpServerConfig? {
        guard isRunning, let port else { return nil }
        return McpServerConfig(
            type: "http",
            name: TerminalMCP.serverName,
            url: "http://127.0.0.1:\(port)/mcp",
            headers: []   // dsh 对 http server 的 headers 做数组遍历，缺字段会 TypeError
        )
    }

    var endpointDescription: String {
        guard isRunning, let port else { return "未启动" }
        return "http://127.0.0.1:\(port)/mcp"
    }

    /// 启动（幂等）。只绑 loopback：消费者只有本机 sidecar。
    ///
    /// 注意用 `using:` + requiredLocalEndpoint 而不是 `NWListener(host:port:)`：
    /// 后者在当前 SDK 不存在（编译错 extra argument 'port'）。port 传 0 =
    /// 内核指派临时端口，就绪后从 listener.port 读真实值。
    func start() async throws {
        if listener != nil { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: 0)!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.handleConnection(connection) }
        }
        // 就绪前把 state 变化接到 continuation 上；之后就交给 lastEvent 记录。
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue
                        self.isRunning = true
                        self.lastEvent = "已监听 127.0.0.1:\(self.port ?? 0)"
                        continuation.resume()
                    case .failed(let error):
                        self.lastEvent = "监听失败：\(error)"
                        continuation.resume(throwing: error)
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .cancelled:
                    self.isRunning = false
                    self.lastEvent = "已停止"
                case .failed(let error):
                    self.isRunning = false
                    self.lastEvent = "监听器失败：\(error)"
                default:
                    break
                }
            }
        }
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        port = nil
        queue.removeAll()
        processing = false
        lastEvent = "已停止"
    }

    // MARK: 队列（串行：PTY 一次一条命令）

    private final class QueuedCall {
        let id: JSONRPCID
        let command: String
        /// 入队时刻起算的响应 deadline。
        let deadline: Date
        let respond: (McpToolResult) -> Void
        /// 已经给过响应（超时抢跑）。为 true 时后续 respond 全部 no-op。
        var resolved = false

        init(id: JSONRPCID, command: String, deadline: Date, respond: @escaping (McpToolResult) -> Void) {
            self.id = id
            self.command = command
            self.deadline = deadline
            self.respond = respond
        }

        var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }
    }

    /// tools/call 入口：入队并启动处理。
    private func enqueueRunInTerminal(id: JSONRPCID, command: String, respond: @escaping (McpToolResult) -> Void) {
        let call = QueuedCall(id: id, command: command,
                              deadline: Date().addingTimeInterval(softDeadline),
                              respond: respond)
        queue.append(call)
        processQueue()
    }

    private func processQueue() {
        guard !processing else { return }
        // 跳过已被超时抢跑解决掉的队头。
        while let head = queue.first, head.resolved {
            queue.removeFirst()
        }
        guard let head = queue.first else { return }
        queue.removeFirst()
        processing = true
        Task { [weak self] in
            guard let self else { return }
            await self.process(call: head)
            self.processing = false
            self.processQueue()
        }
    }

    private func process(call: QueuedCall) async {
        // ── Phase 1：审批 ──
        guard let gate else {
            respond(call, .failure("审批门未配置（App 内部错误），命令未执行"))
            await yieldUntilIdle()
            return
        }
        let gateBudget = min(gateTimeout, call.remaining - deadlineMargin)
        let gateOutcome = await awaitGate(call.command, timeout: gateBudget)
        if call.resolved { await yieldUntilIdle(); return }
        switch gateOutcome {
        case .reject:
            respond(call, .failure("用户拒绝了这条命令，没有执行。请换一种方式完成用户的请求，或询问用户原因。"))
            await yieldUntilIdle()
            return
        case .timeout:
            gate.cancelTerminalCommandRequest()
            respond(call, .failure("用户未在时限内审批（审批卡已关闭），命令没有执行。"))
            await yieldUntilIdle()
            return
        case .allow:
            break
        }

        // ── Phase 2：等终端就绪且空闲 ──
        guard let executor else {
            respond(call, .failure("执行平面未配置（App 内部错误），命令未执行"))
            await yieldUntilIdle()
            return
        }
        while !executor.isTerminalReady || executor.isCapturingCommand {
            if call.remaining - deadlineMargin <= 0 || call.resolved {
                respond(call, .failure("等待终端就绪超时，命令没有执行。"))
                await yieldUntilIdle()
                return
            }
            try? await Task.sleep(for: idlePollInterval)
        }

        // ── Phase 3：注入 PTY，与软 deadline 赛跑 ──
        let output = await raceCapture(
            call.command,
            executor: executor,
            timeout: call.remaining - deadlineMargin,
            // 超时抢跑之后才收敛的输出：不能进工具结果（dsh 已放弃等待），
            // 转 relay 以 prompt 形式回喂。
            onLateCapture: { [weak self] lateText in
                self?.onLateOutput?(call.command, lateText)
            }
        )
        switch output {
        case .captured(let text):
            respond(call, .success(text))
        case .timeout:
            respond(call, .success("命令已开始在终端执行，但超过 55 秒未收敛（可能是长构建、tail -f 或交互式命令）。执行完毕后输出会以用户消息形式回喂给你；期间用户可以随时在终端里 Ctrl-C。"))
        case .failed(let message):
            respond(call, .failure(message))
        }
        await yieldUntilIdle()
    }

    private func respond(_ call: QueuedCall, _ result: McpToolResult) {
        guard !call.resolved else { return }
        call.resolved = true
        call.respond(result)
    }

    // MARK: 审批等待

    private enum GateOutcome {
        case allow
        case reject
        case timeout
    }

    private func awaitGate(_ command: String, timeout: TimeInterval) async -> GateOutcome {
        guard timeout > 0 else { return .timeout }
        // ⚠️ 不要用 withTaskGroup 做这个赛跑：task group 在作用域退出时
        // **隐式等待所有子任务**，挂在"等用户点允许"上的子任务永远不完，
        // 超时路径赢了 next() 也会卡在组退出（实测：SLEEP 子任务打完 log
        // 后整个函数再不返回）。改用函数级 continuation + 两个非结构化任务，
        // 先到先得，OnceResume 保证只应答一次。
        return await withCheckedContinuation { (continuation: CheckedContinuation<GateOutcome, Never>) in
            let box = OnceResume(continuation)
            Task { @MainActor [weak self] in
                guard let self else {
                    box.resume(.reject)
                    return
                }
                self.gate?.requestTerminalCommand(command) { decision in
                    box.resume(decision == .allow ? .allow : .reject)
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(.timeout)
            }
        }
    }

    // MARK: 执行赛跑

    private enum CaptureOutcome {
        case captured(String)
        case timeout
        case failed(String)
    }

    private func raceCapture(_ command: String,
                             executor: TerminalCommandExecutor,
                             timeout: TimeInterval,
                             onLateCapture: @escaping @MainActor (String) -> Void) async -> CaptureOutcome {
        guard timeout > 0 else { return .timeout }
        // 同 awaitGate：不能用 task group（组退出会等 capture 子任务，
        // 而长命令的 onCapture 可能几分钟后才来）。
        return await withCheckedContinuation { (continuation: CheckedContinuation<CaptureOutcome, Never>) in
            let box = OnceResume(continuation)
            Task { @MainActor [weak self] in
                guard let self else {
                    box.resume(.failed("server 已释放"))
                    return
                }
                self.executor?.runCommandCaptured(command) { output in
                    // 超时已抢跑 → 这次 resume 是迟到者：输出转 relay。
                    if !box.resume(.captured(output)) {
                        onLateCapture(output)
                    }
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                box.resume(.timeout)
            }
        }
    }

    /// 等到终端空闲（下一条命令才能注入；用户自己的命令优先）。
    private func yieldUntilIdle() async {
        while let executor, executor.isCapturingCommand {
            try? await Task.sleep(for: idlePollInterval)
        }
    }

    // MARK: HTTP

    private let maxRequestBytes = 1 << 20   // 1MB 请求体上限

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        pumpReceive(connection, buffer: Data())
    }

    private func pumpReceive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else {
                    connection.cancel()
                    return
                }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count > self.maxRequestBytes {
                    self.sendHTTP(status: 413, body: Data(#"{"error":"request too large"}"#.utf8), on: connection)
                    return
                }
                if let request = HTTPRequest.parse(buffer) {
                    self.handleHTTPRequest(request, on: connection)
                    return
                }
                if isComplete || error != nil {
                    // 半截请求（客户端主动断开之类）：不等了。
                    connection.cancel()
                    return
                }
                self.pumpReceive(connection, buffer: buffer)
            }
        }
    }

    private func handleHTTPRequest(_ request: HTTPRequest, on connection: NWConnection) {
        handledRequests += 1
        switch request.method {
        case "POST":
            guard request.path == "/mcp" else {
                sendJSONRPCError(id: .null, code: .methodNotFound, message: "not found: \(request.path)", on: connection)
                return
            }
            handleJSONRPC(request.body, on: connection)
        case "DELETE":
            // MCP 会话终止（dsh 释放 client 时发）。无状态 server：直接认账。
            sendHTTP(status: 200, body: Data(), on: connection)
        default:
            // GET（SSE 开流）等：本 server 只做请求/响应，不开流。
            sendHTTP(status: 405, body: Data(#"{"error":"method not allowed"}"#.utf8), on: connection)
        }
    }

    /// 处理一个 JSON-RPC 消息（批量为 dsh 用不上的路径；来数组按 parse error 处理）。
    private func handleJSONRPC(_ body: Data, on connection: NWConnection) {
        guard let json = try? JSONSerialization.jsonObject(with: body),
              let message = json as? [String: Any] else {
            sendJSONRPCError(id: .null, code: .parseError, message: "parse error", on: connection)
            return
        }
        guard let method = message["method"] as? String else {
            sendJSONRPCError(id: JSONRPCID.parse(message["id"]) ?? .null, code: .invalidRequest, message: "invalid request", on: connection)
            return
        }
        let id = JSONRPCID.parse(message["id"])
        let params = message["params"] as? [String: Any]

        switch method {
        case "initialize":
            // protocolVersion 必须回显客户端发来的版本（SDK 用自己支持的列表校验）。
            let protocolVersion = (params?["protocolVersion"] as? String) ?? "2025-03-26"
            let result: [String: Any] = [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": TerminalMCP.serverDisplayName, "version": TerminalMCP.serverVersion],
                "instructions": TerminalMCP.instructions,
            ]
            sendJSONRPCResult(id: id, result: result, on: connection)

        case "notifications/initialized":
            // 通知：200 空响应（不能回 202——那会促使客户端去开 SSE 流）。
            sendHTTP(status: 200, body: Data(), on: connection)

        case "ping":
            sendJSONRPCResult(id: id, result: [String: Any](), on: connection)

        case "tools/list":
            let tool: [String: Any] = [
                "name": TerminalMCP.toolName,
                "description": TerminalMCP.toolDescription,
                "inputSchema": StaticJSON.parse(TerminalMCP.inputSchemaJSON) ?? [String: Any](),
            ]
            sendJSONRPCResult(id: id, result: ["tools": [tool]], on: connection)

        case "tools/call":
            handleToolsCall(id: id, params: params, on: connection)

        default:
            if let id {
                sendJSONRPCError(id: id, code: .methodNotFound, message: "method not found: \(method)", on: connection)
            } else {
                // 未知通知：忽略。
                sendHTTP(status: 200, body: Data(), on: connection)
            }
        }
    }

    private func handleToolsCall(id: JSONRPCID?, params: [String: Any]?, on connection: NWConnection) {
        guard let id else {
            sendHTTP(status: 200, body: Data(), on: connection)
            return
        }
        let name = params?["name"] as? String
        let arguments = params?["arguments"] as? [String: Any]
        guard name == TerminalMCP.toolName else {
            sendToolResult(id: id, result: .failure("未知工具 \"\(name ?? "")\"。本 server 只提供 \(TerminalMCP.toolName)。"), on: connection)
            return
        }
        guard let command = (arguments?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            sendToolResult(id: id, result: .failure("缺少 command 参数（要执行的完整 shell 命令）。"), on: connection)
            return
        }
        enqueueRunInTerminal(id: id, command: command) { [weak self] result in
            // 完成回调只会在 MainActor 上被调用（server 整体 @MainActor）。
            self?.sendToolResult(id: id, result: result, on: connection)
        }
    }

    // MARK: 响应写出

    private func sendJSONRPCResult(id: JSONRPCID?, result: [String: Any], on connection: NWConnection) {
        guard let id else {
            sendHTTP(status: 200, body: Data(), on: connection)
            return
        }
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": id.jsonValue, "result": result]
        sendJSONEnvelope(envelope, on: connection)
    }

    private func sendJSONRPCError(id: JSONRPCID, code: JSONRPCErrorCode, message: String, on connection: NWConnection) {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "error": ["code": code.rawValue, "message": message],
        ]
        sendJSONEnvelope(envelope, on: connection)
    }

    private func sendToolResult(id: JSONRPCID, result: McpToolResult, on connection: NWConnection) {
        let envelope: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonValue,
            "result": [
                "content": [["type": "text", "text": result.text]],
                "isError": result.isError,
            ] as [String: Any],
        ]
        sendJSONEnvelope(envelope, on: connection)
    }

    private func sendJSONEnvelope(_ envelope: [String: Any], on connection: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
            sendHTTP(status: 500, body: Data(#"{"error":"serialization failed"}"#.utf8), on: connection)
            return
        }
        sendHTTP(status: 200, body: body, on: connection)
    }

    private func sendHTTP(status: Int, body: Data, on connection: NWConnection) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 411: reason = "Length Required"
        case 413: reason = "Payload Too Large"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "OK"
        }
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: application/json\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n\r\n"
        let payload = Data(header.utf8) + body
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// continuation 的只答一次盒子：超时任务与正常完成可能竞态，
/// 双 resume 会 crash，这里后到者变 no-op。
private final class OnceResume<T> {
    private let continuation: CheckedContinuation<T, Never>
    private let lock = NSLock()
    private var done = false

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    /// resume 并回报"是不是首发"（false = 迟到者，调用方自行处理迟到值）。
    @discardableResult
    func resume(_ value: T) -> Bool {
        lock.lock()
        let shouldResume = !done
        done = true
        lock.unlock()
        if shouldResume {
            continuation.resume(returning: value)
        }
        return shouldResume
    }
}

// MARK: - HTTP 请求解析

/// 最小 HTTP/1.1 请求解析：只要请求行 + Content-Length + body。
/// 不支持 chunked（dsh 的 undici 对 string body 必带 Content-Length）。
private struct HTTPRequest {
    var method: String
    var path: String
    var body: Data

    static func parse(_ buffer: Data) -> HTTPRequest? {
        guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = buffer[buffer.startIndex..<separator.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyStart = separator.upperBound
        let available = buffer.count - bodyStart
        guard available >= contentLength else { return nil }   // body 还没收全
        let body = Data(buffer[bodyStart..<(bodyStart + contentLength)])
        return HTTPRequest(method: method, path: path, body: body)
    }
}

// MARK: - JSON 便利

private enum StaticJSON {
    /// 把 JSON 文本解析成 Any（schema 之类静态 JSON 的加载路径）。
    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
