import Foundation
import Darwin
import CptyShim

/// 自管 PTY：forkpty 拉起 shell，master 端读写，SIGCHLD 回收，TIOCSWINSZ 调整尺寸。
/// 与 SwiftTerm 无关，可命令行单测；UI 层把 master 输出喂给终端视图。
public final class PseudoTerminal {
    public struct Config: Sendable {
        public var executablePath: String
        public var arguments: [String]
        public var workingDirectory: URL?
        /// nil = 沿用白名单后的当前环境（去除 DYLD_*）。
        public var environment: [String: String]?
        public var columns: Int
        public var rows: Int

        public init(executablePath: String = "/bin/zsh",
                    arguments: [String] = [],
                    workingDirectory: URL? = nil,
                    environment: [String: String]? = nil,
                    columns: Int = 100,
                    rows: Int = 40) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.workingDirectory = workingDirectory
            self.environment = environment
            self.columns = columns
            self.rows = rows
        }
    }

    public private(set) var childPID: pid_t = -1
    public private(set) var slaveDevicePath: String?
    public private(set) var isRunning = false

    public var onOutput: ((Data) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private var masterFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.cogniterm.pty")
    private var readSource: DispatchSourceRead?
    private var exited = false

    public init() {}

    public func launch(_ config: Config = Config()) throws {
        var windowSize = winsize(ws_row: UInt16(config.rows),
                                 ws_col: UInt16(config.columns),
                                 ws_xpixel: 0, ws_ypixel: 0)

        // argv
        let argvStrings = [config.executablePath] + config.arguments
        let cArgv = argvStrings.map { strdup($0) }
        defer { cArgv.forEach { free($0) } }
        var argv = cArgv + [nil]

        // envp（execve 需要；未显式给定时过滤掉 DYLD_* 注入）
        let env = config.environment ?? PseudoTerminal.sanitizedEnvironment()
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") }
        defer { cEnv.forEach { free($0) } }
        var envp = cEnv + [nil]

        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &windowSize)
        guard pid >= 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EAGAIN)
        }

        if pid == 0 {
            // 子进程
            if let cwd = config.workingDirectory {
                _ = chdir(cwd.path)
            }
            execve(config.executablePath, argv, envp)
            // 仅当 exec 失败到达这里
            _ = Darwin.exit(127)
        }

        // 父进程
        self.masterFD = masterFD
        self.childPID = pid
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(masterFD, F_GETPATH, &buffer) == 0 {
            self.slaveDevicePath = String(cString: buffer)
        }
        isRunning = true
        startReading(masterFD: masterFD)
    }

    public func write(_ data: Data) {
        guard masterFD >= 0 else { return }
        _ = data.withUnsafeBytes { pointer in
            Darwin.write(masterFD, pointer.baseAddress, data.count)
        }
    }

    public func sendInterrupt() {
        // 交给终端行规程生成 SIGINT（比直接 kill 更接近真实按键）。
        write(Data([0x03]))
    }

    public func setSize(columns: Int, rows: Int) {
        guard masterFD >= 0 else { return }
        _ = dsh_set_winsize(masterFD, UInt16(rows), UInt16(columns))
    }

    /// 结束进程组：forkpty 的子进程是会话首进程，-pid 覆盖其整个进程组。
    public func terminate(signal: Int32 = SIGTERM) {
        guard childPID > 0 else { return }
        kill(-childPID, signal)
    }

    public func forceKill() {
        terminate(signal: SIGKILL)
    }

    // MARK: - private

    private func startReading(masterFD: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let estimated = source.data
            var buffer = Data(count: estimated > 0 ? Int(estimated) : 4096)
            let byteCount = buffer.count
            let count = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(masterFD, ptr.baseAddress, byteCount)
            }
            if count > 0 {
                self.onOutput?(buffer.prefix(count))
            } else if count == 0 {
                // 会话首进程退出后 master 收到 EOF——在此沙箱中比进程信号源更可靠。
                self.readSource?.cancel()
                self.reap()
            }
        }
        readSource = source
        source.resume()
    }

    private func reap() {
        queue.async { [weak self] in
            guard let self, self.childPID > 0 else { return }
            var status: Int32 = 0
            while waitpid(self.childPID, &status, 0) == -1 && errno == EINTR {}
            self.handleExit(status: status)
        }
    }

    private func handleExit(status: Int32) {
        guard !exited else { return }
        exited = true
        isRunning = false
        readSource?.cancel()
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
        let code: Int32
        if PseudoTerminal.wifExited(status) {
            code = PseudoTerminal.wExitStatus(status)
        } else if PseudoTerminal.wifSignaled(status) {
            code = 128 + PseudoTerminal.wTermSig(status)
        } else {
            code = -1
        }
        onExit?(code)
    }

    // wait 状态位（sys/wait.h 宏在 Swift 不可用，按位定义展开）。
    private static func wifExited(_ status: Int32) -> Bool { (status & 0o177) == 0 }
    private static func wExitStatus(_ status: Int32) -> Int32 { (status >> 8) & 0o377 }
    private static func wifSignaled(_ status: Int32) -> Bool {
        let core = status & 0o177
        return core != 0o177 && core != 0
    }
    private static func wTermSig(_ status: Int32) -> Int32 { status & 0o177 }

    private static func sanitizedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("DYLD_")
        }
    }
}
