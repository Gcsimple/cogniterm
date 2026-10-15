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

    private var pumpTask: Task<Void, Never>?
    private var pending: [JSONId: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextIntId: Int64 = 1
    private var started = false
    private var serverHandler: ServerRequestHandler?

    private let notificationContinuation: AsyncStream<Notification>.Continuation
    public let notifications: AsyncStream<Notification>

    public init(transport: RPCTransport,
                encoder: JSONEncoder = .acp,
                decoder: JSONDecoder = .acp) {
        self.transport = transport
        self.encoder = encoder
        self.decoder = decoder
        var cont: AsyncStream<Notification>.Continuation!
        let stream = AsyncStream { cont = $0 }
        self.notifications = stream
        self.notificationContinuation = cont
    }

    public var isRunning: Bool { started }

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
                await handleServerRequest(id: envelope.id!, method: envelope.method!, params: envelope.params)
            } else if let id = envelope.id {
                await settle(id: id, result: envelope.result, error: envelope.error)
            } else if let method = envelope.method {
                let data: Data?
                if let params = envelope.params {
                    data = try? params.reencoded(using: encoder)
                } else {
                    data = nil
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
