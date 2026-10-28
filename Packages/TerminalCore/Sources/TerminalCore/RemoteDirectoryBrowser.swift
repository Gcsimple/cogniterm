import Foundation

/// 远端一次目录列举的结果。
public struct RemoteDirectoryListing: Equatable, Sendable {
    /// 远端 `pwd` 出来的**绝对**路径（`~` / 相对路径都在这里被解开）。
    public var path: String
    /// 子目录名（不含父路径，不含结尾 `/`），按名称排序。
    public var directories: [String]

    public init(path: String, directories: [String]) {
        self.path = path
        self.directories = directories
    }
}

/// 远端目录浏览失败的原因。文案直接给用户看（选择器里 inline 展示）。
public enum RemoteDirectoryError: Error, Equatable, LocalizedError {
    /// 该主机需要交互认证（密码 / 未加载的私钥）。
    case authenticationRequired
    /// 首次连接、主机密钥还没写进 known_hosts。
    case hostKeyUnknown
    /// 连不上（DNS / 拒绝 / 超时）。
    case unreachable(String)
    /// 连上了，但这个目录进不去（不存在 / 权限 / 不合法）。
    case unreadable(String)
    case timedOut
    case notAbsolute(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationRequired:
            return "该主机需要交互认证（密码或未加载的私钥），无法在后台浏览目录。"
                 + "请先在终端里连一次，或直接手动输入路径。"
        case .hostKeyUnknown:
            return "主机密钥尚未信任（known_hosts 里没有这台机器）。"
                 + "先在终端里连一次完成确认，再回来浏览目录。"
        case .unreachable(let detail):
            return "连不上主机：\(detail)"
        case .unreadable(let path):
            return "目录不可达：\(path)（不存在，或没有权限）"
        case .timedOut:
            return "远端响应超时（20 秒）。目录可能很大，或网络已断。"
        case .notAbsolute(let path):
            return "需要一个绝对路径或 ~ 开头的路径，收到：\(path)"
        }
    }
}

/// 远端目录浏览器：在**独立的一次性 ssh 连接**里执行 `cd && pwd && ls`。
///
/// ## 为什么不开第二条 PTY / 不复用已连上的会话
///
/// 复用已连接的 PTY 看似省钱，实际上代价很大：注入的 `ls` 会刷在用户屏幕上，
/// 输出还得跟正在跑的命令抢同一个捕获通道（`TerminalSession.runState` 只有
/// 一份），而这个能力往往在「远端正跑着构建」时被用——正是不能打扰的时刻。
///
/// 所以走 `ssh host <cmd>`（`TerminalProfile.sshExec`）：不分配 tty、不靠近
/// 用户的终端、失败即返回。代价是要求免密（BatchMode），命中不了就**降级成
/// 手动输入**，而不是卡住或猜。
///
/// ## 为什么不 grep，而在本地解析
///
/// 远端命令只有 `cd` / `pwd` / `ls -1Ap` 三条最基本的命令。任何 `grep` / `awk`
/// 都会引入"远端有没有装"的不确定性（BSD vs GNU 的参数还不一样），而把解析
/// 放在本地是纯函数，能单测。
public enum RemoteDirectoryBrowser {

    /// 列举的上限：一个目录几千个子目录时，选择器也不需要全部列出。
    public static let maxEntries = 300

    /// 单次探测的超时。远端 `ls` 在 NFS 挂载上可能很慢，给足余量。
    public static let defaultTimeout: TimeInterval = 20

    // MARK: - 远端命令（纯函数，可单测）

    /// 把用户输入翻成**远端 shell 里安全**的路径表达式。
    ///
    /// 唯一的特殊处理是 `~`：它必须留给远端 shell 展开，一旦被引号包住就变成
    /// 一个名字叫 `~` 的字面目录（`no such file`）。所以只把 `~` 本身留在引号外，
    /// 后面那段照样引号化——`~/`'my dir'` 在 shell 里会拼成 `~/my dir`。
    public static func remotePathExpression(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "~" { return "~" }
        if trimmed == "/" { return "/" }
        if trimmed.hasPrefix("~/") {
            return "~/" + ShellCommand.singleQuoted(String(trimmed.dropFirst(2)))
        }
        return ShellCommand.singleQuoted(trimmed)
    }

    /// 一次列举要跑的远端命令。
    ///
    /// - `cd` 失败时整条 `&&` 短路，退出码非 0、stdout 为空 → 调用方判「目录不可达」。
    /// - `pwd` 把 `~` / 相对路径**解开**，UI 才能一直维护绝对路径（不会越点越歪）。
    /// - `ls -1Ap`：单列、除 `.`/`..`、目录名带尾斜杠。BSD 与 GNU 都支持。
    public static func listCommand(path: String) -> String {
        "cd -- \(remotePathExpression(path)) 2>/dev/null && pwd && ls -1Ap"
    }

    /// 切到某个远程目录的命令（注入到**已连接**的交互 shell 用）。
    ///
    /// 与 `ShellCommand.directoryChange(toAbsolutePath:)` 的差别只有一处、但很要命：
    /// 那个版本把整段路径单引号化，`~` 于是变成一个叫 `~` 的字面目录；
    /// 远程目录常常就是 `~/proj`，必须走这里。
    public static func directoryChangeCommand(_ path: String) -> String {
        "cd -- " + remotePathExpression(path)
    }

    // MARK: - 输出解析（纯函数，可单测）

    /// 解析 `listCommand` 的输出。第一行是 pwd，其余是条目。
    ///
    /// 只保留**目录**（`ls -p` 给目录加了尾斜杠），文件与符号链接一律丢弃——
    /// 选择器要的是"进哪个目录"，混进文件名只会让人误点。
    public static func parse(_ output: String) -> RemoteDirectoryListing? {
        let lines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.hasPrefix("/") else { return nil }

        var directories: [String] = []
        for line in lines.dropFirst() {
            guard line.hasSuffix("/") else { continue }
            let name = String(line.dropLast())
            guard !name.isEmpty, name != ".", name != ".." else { continue }
            directories.append(name)
        }
        return RemoteDirectoryListing(
            path: first,
            directories: Array(directories.sorted().prefix(maxEntries))
        )
    }

    // MARK: - 执行

    /// 列举 `path` 下的子目录。`path` 可以是 `~` 或 `~/xxx`。
    ///
    /// 抛出的错误都是 `RemoteDirectoryError`，文案已经面向用户。
    public static func list(
        target: SSHTarget,
        path: String,
        controlSocketPath: String? = nil,
        timeout: TimeInterval = defaultTimeout
    ) async throws -> RemoteDirectoryListing {
        try await withCheckedThrowingContinuation { continuation in
            // 阻塞的 Process 等待放到后台线程：调用点是 @MainActor 的视图，
            // 在主线程上 waitUntilExit 会直接把窗口冻住。
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let listing = try listSync(target: target,
                                               path: path,
                                               controlSocketPath: controlSocketPath,
                                               timeout: timeout)
                    continuation.resume(returning: listing)
                } catch let error as RemoteDirectoryError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: RemoteDirectoryError.unreachable("\(error)"))
                }
            }
        }
    }

    /// 同步版本（单测直接打这里，不必绕 async）。
    static func listSync(
        target: SSHTarget,
        path: String,
        controlSocketPath: String? = nil,
        timeout: TimeInterval
    ) throws -> RemoteDirectoryListing {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || trimmed == "~"
                || trimmed.hasPrefix("~/") || trimmed.hasPrefix("/") else {
            throw RemoteDirectoryError.notAbsolute(path)
        }

        let profile = TerminalProfile.sshExec(target,
                                              remoteCommand: listCommand(path: trimmed),
                                              controlSocketPath: controlSocketPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: profile.executablePath)
        process.arguments = profile.arguments
        process.environment = profile.environment
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw RemoteDirectoryError.unreachable("无法启动 ssh：\(error.localizedDescription)")
        }

        // 两个管道必须**并发**读：先 waitUntilExit 再读，输出超过管道缓冲（64KB）
        // 时子进程会堵在 write 上，而我们堵在 wait 上——经典死锁。
        let stdoutBox = PipeBox()
        let stderrBox = PipeBox()
        let reading = DispatchGroup()
        for (pipe, box) in [(stdoutPipe, stdoutBox), (stderrPipe, stderrBox)] {
            reading.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                box.append(pipe.fileHandleForReading.readDataToEndOfFile())
                reading.leave()
            }
        }

        // 超时标志跨线程写：watchdog 在后台队列置位，主线程在进程退出后读。
        let didTimeout = AtomicFlag()
        let watchdog = DispatchSource.makeTimerSource(queue: .global())
        watchdog.schedule(deadline: .now() + timeout)
        watchdog.setEventHandler {
            guard process.isRunning else { return }
            didTimeout.set()
            process.terminate()
        }
        watchdog.resume()
        defer { watchdog.cancel() }

        process.waitUntilExit()
        reading.wait()

        if didTimeout.value { throw RemoteDirectoryError.timedOut }
        let stdout = String(data: stdoutBox.value, encoding: .utf8) ?? ""
        let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw classify(stderr: stderr, exitCode: process.terminationStatus,
                           path: trimmed, stdout: stdout)
        }
        guard let listing = parse(stdout) else {
            // 退出码 0 但没有 pwd 行：极少见（ls 不存在之类），按不可读处理。
            throw RemoteDirectoryError.unreadable(trimmed)
        }
        return listing
    }

    /// 把 ssh 的 stderr 翻成可执行建议。
    ///
    /// 分这三类而不是笼统报"连接失败"：用户下一步动作完全不同——
    /// 认证要去终端输密码，主机密钥要先去终端确认一次，网络问题要去查网络。
    static func classify(stderr: String,
                         exitCode: Int32,
                         path: String,
                         stdout: String) -> RemoteDirectoryError {
        let text = stderr.lowercased()
        if text.contains("permission denied")
            || text.contains("publickey")
            || text.contains("batchmode")
            || text.contains("no more authentication methods") {
            return .authenticationRequired
        }
        if text.contains("host key verification failed")
            || text.contains("remote host identification has changed")
            || text.contains("no rsa host key is known")
            || text.contains("no ed25519 host key is known")
            || text.contains("no ecdsa host key is known") {
            return .hostKeyUnknown
        }
        // `cd` 失败：ssh 本身连上了，命令退出码是远端 shell 给的（1/2），stdout 空。
        if stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           exitCode == 1 || exitCode == 2 {
            return .unreadable(path)
        }
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .unreachable(detail.isEmpty ? "ssh 退出码 \(exitCode)" : detail)
    }

    /// 管道数据的小锁盒子（读线程与主线程之间只传一次，但读写仍要串行）。
    private final class PipeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// 一次性置位的线程安全布尔。
    private final class AtomicFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false

        func set() {
            lock.lock()
            flag = true
            lock.unlock()
        }

        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return flag
        }
    }
}

/// 给一条命令加上「先在指定目录里执行」的前置条件。
///
/// ## 为什么必须有这一层
///
/// agent 的 `run_in_terminal` 只交命令文本，它**以为自己站在哪个目录**是写不进
/// 命令的。SSH 会话里那个目录在远端，而终端可能停在完全别的地方（用户自己
/// `cd` 过、或者连接后压根没进项目）。不补前置条件的话，同一条 `ls` 在
/// 「agent 以为的目录」和「真正执行的目录」里会得到两个不同的世界，而 agent
/// 无从察觉——它会把错的输出当成事实继续推理。
///
/// ## 为什么单行 / 多行分开处理
///
/// `cd X && a\nb` 里的 `&&` 只约束 **a**，`b` 是无条件执行的——真正危险的多行
/// 命令（`git add .` 后面接 `rm -rf`）恰好就长这样。多行一律包进子 shell，
/// 让 `&&` 对整块生效。
public enum RemoteCommand {
    public static func withWorkingDirectory(_ directory: String?, command: String) -> String {
        let dir = directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !dir.isEmpty else { return command }
        let prefix = RemoteDirectoryBrowser.directoryChangeCommand(dir) + " && "
        guard command.contains(where: \.isNewline) else { return prefix + command }
        return prefix + "(\n" + command + "\n)"
    }
}
