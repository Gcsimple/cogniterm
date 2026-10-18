import Foundation

/// App 侧审批应答策略（严格模式弹原生卡；规则模式自动应答；闭关模式全部拒绝）。
public protocol PermissionAnswerer: Sendable {
    /// 对一次 request_permission 给出应答；UI 超时也应在实现内返回 .cancel()/reject。
    func answer(_ request: PermissionRequestParams) async -> PermissionResponse
}

/// 默认 fail-closed 应答器：全部拒绝。保证 answerer 链路断裂时不发生放行。
public struct DenyAllAnswerer: PermissionAnswerer {
    public init() {}
    public func answer(_ request: PermissionRequestParams) async -> PermissionResponse { .reject() }
}

/// 把 ACP server 反向请求路由到 App：
/// - session/request_permission → PermissionAnswerer（审批卡 / 规则引擎）
/// - fs/read_text_file           → 可选的文件读取回调（v1 默认 -32601；
///                                 接上后按 workspace 边界 + 大小上限 fail-closed）
public actor PermissionBroker: ServerRequestHandler {
    private var answerer: PermissionAnswerer
    private var fsReader: (@Sendable (String, Int?, Int?) async throws -> String)?

    public init(answerer: PermissionAnswerer = DenyAllAnswerer()) {
        self.answerer = answerer
    }

    public func setAnswerer(_ answerer: PermissionAnswerer) {
        self.answerer = answerer
    }

    /// (path, line, limit) → 文本内容。实现方负责 workspace 边界与大小上限。
    public func setFileSystemReader(_ reader: @Sendable @escaping (String, Int?, Int?) async throws -> String) {
        self.fsReader = reader
    }

    public func handleServerRequest(method: String, params: Data) async throws -> Data? {
        switch method {
        case AcpMethod.requestPermission:
            let request = try JSONDecoder.acp.decode(PermissionRequestParams.self, from: params)
            let response = await answerer.answer(request)
            return try JSONEncoder.acp.encode(response)
        case AcpMethod.fsReadTextFile:
            guard let fsReader else { return nil }
            let request = try JSONDecoder.acp.decode(FsReadTextFileParams.self, from: params)
            let content = try await fsReader(request.path, request.line, request.limit)
            return try JSONEncoder.acp.encode(FsReadTextFileResult(content: content))
        default:
            return nil
        }
    }
}
