import Foundation

/// 一行 JSON 帧的双向字节通道。
public protocol RPCTransport: AnyObject, Sendable {
    /// 对端发来的完整行（不含换行符）。
    var lines: AsyncStream<Data> { get }
    /// 通道终止（EOF / 进程退出）时回调一次。
    var onEnded: (() -> Void)? { get set }

    func open() throws
    /// 写入一行并自动补 `\n`。
    func writeLine(_ data: Data) throws
    /// 半关闭写端（stdin EOF），ACP 侧触发有界正常关闭。
    func closeWriting()
    /// 强制终止（SIGTERM/SIGKILL 语义由实现决定）。
    func terminate()
}

/// 通过子进程 stdin/stdout 承载 ACP 通道；stderr 单独引流到诊断回调，绝不混入帧流。
public final class ProcessTransport: RPCTransport, @unchecked Sendable {
    public struct Config: Sendable {
        public var executableURL: URL
        public var arguments: [String]
        /// 完整环境（白名单注入，不从父进程继承 DYLD_*）。
        public var environment: [String: String]
        public var currentDirectoryURL: URL?

        public init(executableURL: URL,
                    arguments: [String] = [],
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    currentDirectoryURL: URL? = nil) {
            self.executableURL = executableURL
            self.arguments = arguments
            self.environment = environment
            self.currentDirectoryURL = currentDirectoryURL
        }
    }

    public var onEnded: (() -> Void)?
    /// stderr 诊断输出（按行）。
    public var onDiagnostic: ((String) -> Void)?

    public private(set) lazy var lines: AsyncStream<Data> = makeLinesStream()

    private let config: Config
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let framer = LineFramer()

    private var linesContinuation: AsyncStream<Data>.Continuation?
    private let stateLock = NSLock()
    private var ended = false

    public init(config: Config) {
        self.config = config
    }

    public func open() throws {
        process.executableURL = config.executableURL
        process.arguments = config.arguments
        process.environment = config.environment
        if let cwd = config.currentDirectoryURL {
            process.currentDirectoryURL = cwd
        }
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF：readabilityHandler 收到空数据。
                self?.finish()
                return
            }
            guard let frames = self?.framer.append(chunk), !frames.isEmpty else { return }
            for frame in frames { self?.linesContinuation?.yield(frame) }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            text.split(separator: "\n", omittingEmptySubsequences: true).forEach {
                self?.onDiagnostic?(String($0))
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        try process.run()
    }

    public func writeLine(_ data: Data) throws {
        var frame = data
        frame.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: frame)
    }

    public func closeWriting() {
        try? stdinPipe.fileHandleForWriting.close()
    }

    public func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    private func makeLinesStream() -> AsyncStream<Data> {
        AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.finish()
            }
            self.linesContinuation = continuation
        }
    }

    private func finish() {
        stateLock.lock()
        if ended {
            stateLock.unlock()
            return
        }
        ended = true
        stateLock.unlock()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        linesContinuation?.finish()
        onEnded?()
    }
}

/// 内存回环通道：测试用。对每条写入同步产生 0..n 条应答；测试也可主动 push 服务端请求/通知。
public final class LoopbackTransport: RPCTransport, @unchecked Sendable {
    public var onEnded: (() -> Void)?
    public let lines: AsyncStream<Data>

    /// 脚本化对端：收到一行 JSON，返回需要回复的行（可为空）。
    public var responder: ((Data) -> [Data])?
    private var continuation: AsyncStream<Data>.Continuation?

    public init() {
        // 流与续体在 init 时一次性建好：lazy 化会让 writeLine/push 在
        // 分帧泵首次迭代 lines 之前静默丢帧（continuation 尚为 nil），
        // 表现为请求永久挂起。eager 初始化从根上消除该竞态。
        var cont: AsyncStream<Data>.Continuation!
        lines = AsyncStream { cont = $0 }
        continuation = cont
    }

    public func open() throws { /* 内存通道无需启动 */ }

    public func writeLine(_ data: Data) throws {
        guard let responder else { return }
        for reply in responder(data) {
            continuation?.yield(reply)
        }
    }

    public func closeWriting() { finish() }
    public func terminate() { finish() }

    /// 模拟服务端主动推来一行（请求 / 通知 / 响应）。
    public func push(_ data: Data) {
        continuation?.yield(data)
    }

    /// 便捷：推一条 JSON 编码对象。
    public func pushJSON<T: Encodable>(_ value: T, encoder: JSONEncoder = .acp) throws {
        push(try encoder.encode(value))
    }

    private func finish() {
        continuation?.finish()
        continuation = nil
        onEnded?()
    }
}
