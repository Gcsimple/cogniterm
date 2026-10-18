import Foundation

struct EmptyParams: Encodable {}

public enum AcpError: Error, Equatable {
    case notStarted
    case ended
    case timeout(method: String)
    case rpc(code: Int, message: String)
    case encode(String)
    case decode(String)
    case transport(String)
    case missingResult
}

/// 处理 dsh（server）反向发来的请求，如 `session/request_permission`、`fs/readTextFile`。
public protocol ServerRequestHandler: Sendable {
    /// 返回应答的原始 result JSON；返回 nil 表示方法未实现，回 -32601。
    func handleServerRequest(method: String, params: Data) async throws -> Data?
}

extension JSONEncoder {
    /// ACP 全部使用 camelCase（sessionId/stopReason/protocolVersion），默认策略即可。
    public static let acp: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    public static let acp = JSONDecoder()
}

/// 单个 JSON-RPC 消息的弱类型信封：请求/响应/通知三种形态共用。
struct RPCEnvelope: Decodable {
    let id: JSONId?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: RPCErrorBody?
}

struct RPCErrorBody: Decodable {
    let code: Int
    let message: String
}

struct OutgoingRequest: Encodable {
    let jsonrpc = "2.0"
    let id: JSONId
    let method: String
    let params: AnyEncodable?
}

struct OutgoingNotification: Encodable {
    let jsonrpc = "2.0"
    let method: String
    let params: AnyEncodable?
}

struct OutgoingSuccess: Encodable {
    let jsonrpc = "2.0"
    let id: JSONId
    let result: AnyEncodable
}

struct OutgoingFailure: Encodable {
    struct ErrBody: Encodable { let code: Int; let message: String }
    let jsonrpc = "2.0"
    let id: JSONId
    let error: ErrBody
}

/// ACP 连接：NDJSON 分帧的 JSON-RPC 2.0 双向多路复用。
/// - client → server：`request`/`notify`
/// - server → client：通知走 `notifications` 流；请求交给 `ServerRequestHandler`
public actor AcpConnection {
    public typealias Notification = (method: String, params: Data?)

    private let transport: RPCTransport
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// toolCallId → 快照的关联缓存（dsh 审批请求只带 toolCallId，
    /// 命令文本必须由先行的 tool_call 事件按到达序入库——在分帧路径同步记录，
    /// 与后续 server 请求的处理严格保序）。
    private let toolCallTracker: ToolCallTracker?

    private var pumpTask: Task<Void, Never>?
    private var pending: [JSONId: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextIntId: Int64 = 1
    private var started = false
    private var serverHandler: ServerRequestHandler?

    private let notificationContinuation: AsyncStream<Notification>.Continuation
    public let notifications: AsyncStream<Notification>
    /// 服务端反向请求的处理链：按到达序串行，但**不在分帧泵上 await**——
    /// request_permission 会挂起等待用户审批，若阻塞泵，紧随其后的
    /// prompt 响应（stopReason）永远排不上队，整条连接假死。
    private var serverRequestChain: Task<Void, Never>?

    public init(transport: RPCTransport,
                encoder: JSONEncoder = .acp,
                decoder: JSONDecoder = .acp,
                toolCallTracker: ToolCallTracker? = nil) {
        self.transport = transport
        self.encoder = encoder
        self.decoder = decoder
        self.toolCallTracker = toolCallTracker
        var cont: AsyncStream<Notification>.Continuation!
        let stream = AsyncStream { cont = $0 }
        self.notifications = stream
        self.notificationContinuation = cont
    }

    public var isRunning: Bool { started }

    /// 查询 tool_call 快照（供审批卡/规则引擎在 request_permission 到达时补给命令文本）。
    public func toolCallSnapshot(for toolCallId: String) -> ToolCallSnapshot? {
        toolCallTracker?.snapshot(for: toolCallId)
    }

    public func start(serverHandler: ServerRequestHandler? = nil) async throws {
        guard !started else { return }
        self.serverHandler = serverHandler
        try transport.open()
        started = true
        pumpTask = Task { [weak self, transport] in
            guard let self else { return }
            for await line in transport.lines {
                await self.dispatch(line)
            }
            await self.handleTransportEnd()
        }
    }

    // MARK: - Client → Server

    public func request<Params: Encodable, Result: Decodable>(
        _ method: String,
        params: Params,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        let value = try await call(method: method, params: params, timeout: timeout)
        let data = try value.reencoded(using: encoder)
        do {
            return try decoder.decode(Result.self, from: data)
        } catch {
            throw AcpError.decode("result of \(method): \(error)")
        }
    }

    /// 无参数请求（ACP 部分方法如 `session/list` 无 params）。
    public func request<Result: Decodable>(
        _ method: String,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        return try await request(method, params: EmptyParams(), timeout: timeout)
    }

    public func notify<Params: Encodable>(_ method: String, params: Params) async throws {
        try ensureRunning()
        let message = OutgoingNotification(method: method, params: AnyEncodable(params))
        try send(message)
    }

    private func call<Params: Encodable>(method: String,
                                         params: Params,
                                         timeout: TimeInterval?) async throws -> JSONValue {
        try ensureRunning()
        let id = JSONId.int(nextIntId)
        nextIntId += 1
        let message = OutgoingRequest(id: id, method: method, params: AnyEncodable(params))

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
                pending[id] = continuation
                do {
                    try send(message)
                } catch {
                    pending[id] = nil
                    continuation.resume(throwing: error)
                    return
                }
                guard let timeout else { return }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.timeOut(id: id, method: method)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.fail(id: id, with: CancellationError()) }
        }
    }

    // MARK: - Frame dispatch

    private nonisolated func dispatch(_ line: Data) async {
        do {
            let envelope = try decoder.decode(RPCEnvelope.self, from: line)
            if envelope.id != nil && envelope.method != nil {
                // 反向请求（request_permission / fs/read_text_file）甩到链上串行处理，
                // 分帧泵继续排空后续帧——审批挂起不再堵死 prompt 响应。
                await enqueueServerRequest(id: envelope.id!, method: envelope.method!, params: envelope.params)
            } else if let id = envelope.id {
                await settle(id: id, result: envelope.result, error: envelope.error)
            } else if let method = envelope.method {
                let data: Data?
                if let params = envelope.params {
                    data = try? params.reencoded(using: encoder)
                } else {
                    data = nil
                }
                // session/update 在分帧路径同步入库 toolCallTracker：
                // 通知的消费者在另一个 Task 上异步处理，而紧随其后的
                // request_permission 会在本路径立即处理——只有同步按到达序记录，
                // 才能保证审批请求拿到命令文本（dsh 服务端以 drainUpdates 保序，
                // 客户端必须同序，否则 rules 模式与审批卡会间歇性丢命令）。
                if method == AcpMethod.sessionUpdate, let data,
                   let note = try? decoder.decode(SessionNotificationParams.self, from: data),
                   let update = note.update {
                    toolCallTracker?.record(update)
                }
                notificationContinuation.yield((method, data))
            }
        } catch {
            // 规约：坏帧忽略，不断连。
            return
        }
    }

    private func settle(id: JSONId, result: JSONValue?, error: RPCErrorBody?) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        if let error {
            continuation.resume(throwing: AcpError.rpc(code: error.code, message: error.message))
        } else if let result {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: AcpError.missingResult)
        }
    }

    private func timeOut(id: JSONId, method: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: AcpError.timeout(method: method))
    }

    private func fail(id: JSONId, with error: Error) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: error)
    }

    /// 把服务端反向请求挂到串行链尾：前一个处理完（用户已审批）才轮到下一个，
    /// 保证响应顺序与到达顺序一致；分帧泵本身不等待。
    private func enqueueServerRequest(id: JSONId, method: String, params: JSONValue?) {
        let previous = serverRequestChain
        serverRequestChain = Task { [previous, weak self] in
            await previous?.value
            await self?.handleServerRequest(id: id, method: method, params: params)
        }
    }

    private func handleServerRequest(id: JSONId, method: String, params: JSONValue?) async {
        let paramsData = try? params?.reencoded(using: encoder)
        do {
            if let result = try await serverHandler?.handleServerRequest(method: method,
                                                                         params: paramsData ?? Data()) {
                try send(OutgoingSuccess(id: id, result: AnyEncodable(RawJSON(data: result))))
            } else {
                try send(OutgoingFailure(id: id, error: .init(code: -32601,
                                                              message: "method not found: \(method)")))
            }
        } catch let error as AcpError {
            let body = OutgoingFailure.ErrBody(code: -32603, message: "\(error)")
            try? send(OutgoingFailure(id: id, error: body))
        } catch {
            let body = OutgoingFailure.ErrBody(code: -32603, message: "\(error)")
            try? send(OutgoingFailure(id: id, error: body))
        }
    }

    private func handleTransportEnd() {
        started = false
        serverRequestChain?.cancel()
        serverRequestChain = nil
        notificationContinuation.finish()
        let waiters = pending
        pending.removeAll()
        for (_, continuation) in waiters {
            continuation.resume(throwing: AcpError.ended)
        }
    }

    /// 有界关闭：优先 stdin EOF（dsh 会排空持久化后退出），再由监督器决定是否升级信号。
    public func closeWriting() async {
        transport.closeWriting()
    }

    public func terminate() async {
        transport.terminate()
    }

    // MARK: - Helpers

    private func ensureRunning() throws {
        if !started { throw AcpError.notStarted }
    }

    private func send<T: Encodable>(_ message: T) throws {
        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            throw AcpError.encode("\(error)")
        }
        do {
            try transport.writeLine(data)
        } catch {
            throw AcpError.transport("\(error)")
        }
    }
}

/// 把已经是 JSON 的 Data 当作 Encodable 原样嵌入（用于服务端请求应答）。
struct RawJSON: Encodable {
    let data: Data

    func encode(to encoder: Encoder) throws {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        try value.encode(to: encoder)
    }
}
