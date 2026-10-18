import Foundation

/// 终端会话的**纯策略**：用哪个 shell、带什么参数、注入什么环境、怎么把路径安全拼进命令行。
///
/// 单独成文件、且**不 import AppKit/SwiftTerm**，是因为这里每一个判定都能在命令行单测，
/// 而终端面板里最贵的几类 bug 恰好全藏在这一层：
/// 子进程 PATH 不全（"还不如 zsh 好用"的直接来源）、父进程代理变量泄漏进 shell、
/// 路径里带空格或单引号把 `cd` 拼坏。
public struct TerminalProfile: Equatable, Sendable {
    public var executablePath: String
    public var arguments: [String]
    public var environment: [String: String]

    public init(executablePath: String, arguments: [String], environment: [String: String]) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.environment = environment
    }

    // MARK: - 常量

    /// `$SHELL` 缺失、指向未知程序、或不可执行时的回落。
    public static let fallbackShellPath = "/bin/zsh"

    /// 只接受这些 shell。`$SHELL` 由用户环境决定，但**不能无条件信任**：它可能指向
    /// 一个包装脚本或已卸载的路径，那时 forkpty 会直接失败、终端一片空白。
    public static let knownShellNames: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "fish"]

    /// 以 **login shell** 启动的 shell。
    ///
    /// 这一条不是口味问题：GUI 进程的 `PATH` 来自 launchd，只有
    /// `/usr/bin:/bin:/usr/sbin:/sbin`，**没有 Homebrew**。login shell 会读
    /// `/etc/zprofile` → `path_helper` → `/etc/paths` + `/etc/paths.d/*`，
    /// 把我们自己拼的 PATH 修正过来。Terminal.app 默认也是 login shell。
    public static let loginShellNames: Set<String> = ["zsh", "bash", "sh", "ksh", "fish"]

    /// 必须从子进程环境里剔掉的两类变量（见 `sanitize`）。
    public static let proxyVariables: [String] = [
        "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy",
        "NODE_USE_ENV_PROXY",
    ]

    public static let defaultTerm = "xterm-256color"
    public static let defaultColorTerm = "truecolor"
    public static let defaultLocale = "en_US.UTF-8"

    // MARK: - shell 解析

    /// 从 `$SHELL` 解析要启动的可执行文件；不可用时回落 `/bin/zsh`。
    ///
    /// - Parameter isExecutable: 为单测注入。默认查真实文件系统。
    public static func resolveShellPath(
        environment: [String: String],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        guard let raw = environment["SHELL"], raw.hasPrefix("/") else {
            return fallbackShellPath
        }
        let name = (raw as NSString).lastPathComponent
        guard knownShellNames.contains(name) else { return fallbackShellPath }
        guard isExecutable(raw) else { return fallbackShellPath }
        return raw
    }

    /// login + interactive。非白名单 shell 只给 `-i`（`dash` 不认 `-l`）。
    public static func arguments(forShellAt path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        return loginShellNames.contains(name) ? ["-l", "-i"] : ["-i"]
    }

    // MARK: - 环境

    /// 剔掉不该继承给子 shell 的变量。
    ///
    /// - 代理变量：本机每次工具调用都会往环境里注入
    ///   `HTTP(S)_PROXY=http://127.0.0.1:<临时端口>`，端口随调用结束消失。
    ///   留着就是一个指向死端口的代理，用户在里面 `curl`/`git`/`pip` 全部失败——
    ///   而且报错指向"网络不通"，跟真实原因（父进程留下了垃圾）毫无关系。
    /// - `DYLD_*`：`PseudoTerminal.launch` 只在 `environment == nil` 时替我们过滤，
    ///   我们自己给环境时它不管，所以这里必须自己来。
    public static func sanitize(_ base: [String: String]) -> [String: String] {
        base.filter { key, _ in
            !key.hasPrefix("DYLD_") && !proxyVariables.contains(key)
        }
    }

    /// 补上终端语义必需、但 GUI 父进程环境里通常没有的变量。
    ///
    /// `TERM` 是**覆盖**（视图是 xterm-256color 兼容的实现，父进程可能在 tmux/screen 里）；
    /// `LANG` 只在完全缺失时补（用户显式设了 `zh_CN.UTF-8` 就该尊重）。
    public static func enrich(
        _ base: [String: String],
        term: String = defaultTerm,
        colorTerm: String = defaultColorTerm,
        programName: String? = nil,
        programVersion: String? = nil,
        locale: String = defaultLocale
    ) -> [String: String] {
        var environment = base
        environment["TERM"] = term
        environment["COLORTERM"] = colorTerm
        if let programName, !programName.isEmpty {
            environment["TERM_PROGRAM"] = programName
        }
        if let programVersion, !programVersion.isEmpty {
            environment["TERM_PROGRAM_VERSION"] = programVersion
        }
        let hasLocale = ["LANG", "LC_ALL", "LC_CTYPE"].contains { key in
            guard let value = environment[key] else { return false }
            return !value.isEmpty
        }
        if !hasLocale {
            environment["LANG"] = locale
        }
        return environment
    }

    // MARK: - 组装

    public static func standard(
        workingDirectory: URL,
        columns: Int,
        rows: Int,
        base: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        programName: String? = nil,
        programVersion: String? = nil
    ) -> TerminalProfile {
        let shell = resolveShellPath(environment: base, isExecutable: isExecutable)
        let environment = enrich(
            sanitize(base),
            programName: programName,
            programVersion: programVersion
        )
        return TerminalProfile(
            executablePath: shell,
            arguments: arguments(forShellAt: shell),
            environment: environment
        )
    }

    public func ptyConfig(workingDirectory: URL, columns: Int, rows: Int) -> PseudoTerminal.Config {
        PseudoTerminal.Config(
            executablePath: executablePath,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            columns: columns,
            rows: rows
        )
    }
}

/// 往交互式 shell 里注入一条命令时要做的文本处理。
public enum ShellCommand {
    /// POSIX 单引号转义：闭合、转义、重开。`it's` → `'it'\''s'`。
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 切目录。`--` 让以 `-` 开头的路径不会被当选项；路径整体加引号，空格/引号/中文都安全。
    public static func directoryChange(toAbsolutePath path: String) -> String {
        "cd -- " + singleQuoted(path)
    }

    /// 交互式 shell 认 **CR**（`\r`）为回车；`\n` 在 zsh 的 ZLE 下不总是等价。
    public static func submitted(_ command: String) -> String {
        command + "\r"
    }
}
