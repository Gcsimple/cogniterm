import Foundation

/// SSH 连接目标：纯数据 + 校验，不碰文件系统、不碰网络。
///
/// 与 `TerminalProfile` 同一层（无 AppKit / 无 SwiftTerm），因为这里每个判定
/// 都能在命令行单测——而 SSH 这一层最贵的 bug 恰好是"参数拼错"与"选项注入"：
/// 用户输入直接进 `ssh` 的 argv，前导 `-` 会被当成选项（`-oProxyCommand=…`
/// 就是一次本地命令执行）。
public struct SSHTarget: Equatable, Sendable, Codable {
    public var host: String
    public var port: Int
    public var username: String?
    /// 私钥路径（支持 `~/` 展开）。
    public var identityFilePath: String?
    /// 跳板：`user@bastion` 或 `user@bastion:2222`（ssh -J 语法）。
    public var jumpHost: String?

    public static let defaultPort = 22

    public init(host: String,
                port: Int = SSHTarget.defaultPort,
                username: String? = nil,
                identityFilePath: String? = nil,
                jumpHost: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.identityFilePath = identityFilePath
        self.jumpHost = jumpHost
    }

    /// 展示名：`user@host`（无 user 时 `host`）。
    public var displayName: String {
        guard let username, !username.isEmpty else { return host }
        return "\(username)@\(host)"
    }

    // MARK: - 校验

    /// 语法错误清单（空 = 合法）。文案直接面向用户，表单里 inline 展示。
    ///
    /// 只做**语法**校验，不查文件是否存在（纯层没有文件系统语义）：
    /// 私钥路径的存在性由表单层补一句提醒，不阻塞连接（ssh 自己也会报）。
    public func validationErrors() -> [String] {
        var errors: [String] = []

        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("主机不能为空")
        } else if !Self.isSafeToken(host) {
            errors.append("主机名不能包含空白字符，也不能以 - 开头")
        }

        if port < 1 || port > 65535 {
            errors.append("端口必须在 1–65535 之间")
        }

        if let username, !username.isEmpty {
            if !Self.isSafeToken(username) || username.contains("@") {
                errors.append("用户名不能包含空白、@，也不能以 - 开头")
            }
        }

        if let identity = identityFilePath, !identity.isEmpty {
            if !Self.isSafeToken(identity) {
                errors.append("私钥路径不能包含空白字符，也不能以 - 开头")
            }
        }

        if let jump = jumpHost, !jump.isEmpty {
            if !Self.isSafeToken(jump) || jump.contains(" ")
                || jump.contains(",") {
                errors.append("跳板格式应为 user@host[:port]，不能包含空白或逗号")
            }
        }

        return errors
    }

    public var isValid: Bool { validationErrors().isEmpty }

    // MARK: - 词法工具

    /// argv 直传时的选项注入防线。
    ///
    /// 命令不经过 shell（`PseudoTerminal` 用 forkpty + execvp 传数组），所以
    /// 引号/分号/`$()` 都只是普通字符，**不需要也不应该做 shell 转义**；
    /// 唯一能改变语义的是前导 `-`（会被 ssh 当选项，`-oProxyCommand=…`
    /// 等于本地任意命令执行）。
    static func isSafeToken(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("-") else { return false }
        return !value.contains { $0.isWhitespace || $0.isNewline }
    }

    /// `~` 展开：只处理前导 `~` / `~/`（argv 不经过 shell，没人替我们展开）。
    public static func expandTilde(_ path: String,
                                   home: String = NSHomeDirectory()) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst(1) }
        return path
    }
}

extension TerminalProfile {
    /// SSH 会话的启动策略：`/usr/bin/ssh` + 组装好的参数，复用同一套 PTY 管线。
    ///
    /// 为什么走系统 ssh 而不是内嵌协议栈：零依赖、OpenSSH 全量能力
    /// （ProxyJump / ControlMaster / ssh-agent / 证书 / keyboard-interactive /
    /// `~/.ssh/config` / known_hosts）全部跟随系统行为，不需要我们维护密码学栈。
    /// 代价是程序化控制弱（SFTP / 端口转发需另做），属后续阶段。
    public static func ssh(
        _ target: SSHTarget,
        controlSocketPath: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment,
        programName: String? = nil,
        programVersion: String? = nil
    ) -> TerminalProfile {
        var arguments = sshOptionArguments(target)
        // 连接复用：同一目标在 ControlPersist 期内只认证一次，之后新标签页
        // 直接搭上已有通道。这是「每次开标签都要重新输密码」最省事、也最不
        // 碰密码本身的解法——密码只在我们自己的进程外出现过一次。
        if let socket = controlSocketPath, !socket.isEmpty {
            arguments += ["-o", "ControlMaster=auto"]
            arguments += ["-o", "ControlPath=\(socket)"]
            arguments += ["-o", "ControlPersist=600"]
        }
        // 保活：NAT/休眠后让通道自己断，而不是卡在"看起来还活着"的状态。
        // 只有**交互会话**需要它：`sshExec` 是一次性命令，连接活着没意义。
        arguments += ["-o", "ServerAliveInterval=30"]
        arguments += ["-o", "ServerAliveCountMax=3"]
        // 目标放最后：ssh 把最后一个非选项参数当 destination。
        arguments.append(target.host)

        return TerminalProfile(
            executablePath: "/usr/bin/ssh",
            arguments: arguments,
            environment: enrich(
                sanitize(base),
                programName: programName,
                programVersion: programVersion
            )
        )
    }

    /// 一次性远程命令（`ssh host <cmd>`）：**不分配 tty、不交互、失败即返回**。
    ///
    /// 用途是「读一眼远端状态」这类探测（列出目录、读 pwd）。它与交互会话
    /// 的关键差别是 `BatchMode=yes`：需要密码或主机密钥确认时**直接失败**，
    /// 绝不停在那里等输入——后台发起的探测一旦卡在密码提示上，就是一个
    /// 永远不返回的僵尸进程。
    ///
    /// - Parameter remoteCommand: 交给**远端 shell** 解释的完整命令行。调用方
    ///   必须自己转义路径（见 `RemoteDirectoryBrowser.remotePathExpression`）。
    /// - Parameter controlSocketPath: 已认证的复用通道。**这条很关键**：存了
    ///   密码的用户靠它才用得上目录浏览——探测走 BatchMode、不会自己认证，
    ///   搭上已认证的 master 才有身份；不传就只能干等到"需要交互认证"的报错。
    public static func sshExec(
        _ target: SSHTarget,
        remoteCommand: String,
        controlSocketPath: String? = nil,
        connectTimeout: Int = 8,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> TerminalProfile {
        var arguments = sshOptionArguments(target, connectTimeout: connectTimeout)
        arguments += ["-o", "BatchMode=yes"]
        if let socket = controlSocketPath, !socket.isEmpty {
            // `no` 而不是 `auto`：探测只做**从通道**，不该自己变成 master。
            // 自己当 master 会把一个一次性的探测进程变成常驻连接（还认证不了）。
            arguments += ["-o", "ControlMaster=no"]
            arguments += ["-o", "ControlPath=\(socket)"]
        }
        // 不分配 pty：远端拿到的 stdout 是管道，不会有提示符/颜色转义混进来。
        arguments.append("-T")
        arguments.append(target.host)
        // ssh 把 destination 之后的**所有**参数用空格拼成一条命令交给远端 shell，
        // 所以这里必须是一个已经拼好的字符串，而不是数组。
        arguments.append(remoteCommand)
        return TerminalProfile(
            executablePath: "/usr/bin/ssh",
            arguments: arguments,
            environment: enrich(sanitize(base))
        )
    }


    /// 两种用法共用的选项段（连接超时 + 身份参数），**不含 destination**。
    ///
    /// 抽出来是为了让「交互会话」与「一次性命令」走同一套身份参数：两边如果
    /// 各自拼一份，某天补了 `-o` 选项只改一处，另一处就会静默用不同身份连
    /// 同一台机器（表现为"浏览目录能看到，会话里 ls 看不到"这类鬼故事）。
    static func sshOptionArguments(_ target: SSHTarget, connectTimeout: Int = 15) -> [String] {
        // 连接阶段快速失败（不可达的主机不要让人对着黑屏等系统默认 75s）。
        var arguments: [String] = ["-o", "ConnectTimeout=\(connectTimeout)"]

        if let username = target.username, !username.isEmpty {
            arguments += ["-l", username]
        }
        if target.port != SSHTarget.defaultPort {
            arguments += ["-p", String(target.port)]
        }
        if let identity = target.identityFilePath, !identity.isEmpty {
            arguments += ["-i", SSHTarget.expandTilde(identity)]
        }
        if let jump = target.jumpHost, !jump.isEmpty {
            arguments += ["-J", jump]
        }
        return arguments
    }
}
