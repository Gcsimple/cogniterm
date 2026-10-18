import Foundation
import os

public enum SidecarState: String, Sendable, Equatable {
    case idle
    case starting
    case running
    case restarting
    case stopped
    case failed
}

public struct SidecarConfig: Sendable {
    public var executableURL: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectoryURL: URL?
    /// stdin EOF 后等待 dsh 排空持久化的宽限时间。
    public var gracefulShutdownTimeout: TimeInterval
    public var maxRestarts: Int
    /// tool_call 关联缓存（分帧路径同步记录；见 AcpConnection.dispatch）。
    public var toolCallTracker: ToolCallTracker?

    public init(executableURL: URL,
                arguments: [String] = ["--profile", "acp"],
                environment: [String: String],
                currentDirectoryURL: URL? = nil,
                gracefulShutdownTimeout: TimeInterval = 5,
                maxRestarts: Int = 3,
                toolCallTracker: ToolCallTracker? = nil) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.gracefulShutdownTimeout = gracefulShutdownTimeout
        self.maxRestarts = maxRestarts
        self.toolCallTracker = toolCallTracker
    }
}

/// Sidecar 生命周期监督：拉起、EOF 有界关闭、崩溃指数退避重启。
/// 重启恢复动作（session/list + resume）交给调用方注入，避免本层依赖会话语义。
public final class SidecarSupervisor: @unchecked Sendable {
    public private(set) var state: SidecarState = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((SidecarState) -> Void)?
    public var onDiagnostic: ((String) -> Void)?
    /// 每次成功拉起后回调（首次启动与重启），调用方在此执行 initialize / list+resume。
    public var onReady: ((DshAcpClient) async -> Void)?
    /// 崩溃事件（restartCount 已递增）。
    public var onCrash: ((Int, Int32?) -> Void)?

    private let config: SidecarConfig
    private let stateLock = OSAllocatedUnfairLock()
    private var transport: ProcessTransport?
    private var client: DshAcpClient?
    private var serverHandler: ServerRequestHandler?
    private var restartCount = 0
    private var intentionalStop = false

    public init(config: SidecarConfig) {
        self.config = config
    }

    @discardableResult
    public func start(serverHandler: ServerRequestHandler? = nil) async throws -> DshAcpClient {
        stateLock.withLock {
            intentionalStop = false
            restartCount = 0
            self.serverHandler = serverHandler
        }
        return try await spawn(serverHandler: serverHandler)
    }

    private func spawn(serverHandler: ServerRequestHandler?) async throws -> DshAcpClient {
        state = (restartCount == 0) ? .starting : .restarting
        let transport = ProcessTransport(config: .init(
            executableURL: config.executableURL,
            arguments: config.arguments,
            environment: config.environment,
            currentDirectoryURL: config.currentDirectoryURL
        ))
        let client = DshAcpClient(transport: transport, toolCallTracker: config.toolCallTracker)
        transport.onDiagnostic = { [weak self] line in self?.onDiagnostic?(line) }

        let observedClient = client
        transport.onEnded = { [weak self] in
            self?.handleExit(client: observedClient)
        }

        try await client.start(serverHandler: serverHandler)
        self.transport = transport
        self.client = client
        state = .running
        Task { await self.onReady?(client) }
        return client
    }

    private func handleExit(client: DshAcpClient) {
        let (intentional, count) = stateLock.withLock {
            (intentionalStop, restartCount)
        }

        guard !intentional else {
            state = .stopped
            return
        }

        onCrash?(count + 1, nil)

        guard count < config.maxRestarts else {
            state = .failed
            return
        }

        let backoff = pow(2.0, Double(count)) // 1s, 2s, 4s...
        stateLock.withLock {
            restartCount = count + 1
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            guard let self else { return }
            do {
                _ = try await self.spawn(serverHandler: self.serverHandler)
            } catch {
                self.state = .failed
            }
        }
    }

    /// 有界关闭序列：stdin EOF → 等待排空 → SIGTERM →（更极端时由调用方 SIGKILL）。
    public func gracefulShutdown() async {
        stateLock.withLock {
            intentionalStop = true
        }

        await client?.gracefulShutdown()

        let deadline = Date().addingTimeInterval(config.gracefulShutdownTimeout)
        while state != .stopped, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if state != .stopped {
            transport?.terminate()
            state = .stopped
        }
    }

    public func forceTerminate() {
        stateLock.withLock {
            intentionalStop = true
        }
        transport?.terminate()
        state = .stopped
    }
}
