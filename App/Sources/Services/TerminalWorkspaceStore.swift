import Foundation
import TerminalCore

/// 一个被持久化的终端标签。
///
/// 为什么只存 SSH：本地会话恒在首位且不可关闭（它是 agent 的默认执行平面），
/// 所以"恢复本地 shell"没有意义——它一定在。真正会丢的是用户手开的远程标签。
///
/// **不存任何凭据**：`SSHTarget` 里只有 host/port/user/私钥路径/跳板，
/// 没有密码也没有 passphrase。恢复时 ssh 自己按原有方式认证
/// （agent 转发 `SSH_AUTH_SOCK`，或由 ssh 在终端里提示）。
public struct StoredTerminalTab: Codable, Equatable, Sendable {
    public var label: String
    public var host: String
    public var port: Int
    public var username: String?
    public var identityFilePath: String?
    public var jumpHost: String?
    /// 远程执行目录（agent 的命令在这个目录里跑）。
    ///
    /// 可选且**可缺失**：旧版本写的配置文件里没有这个键，合成解码走
    /// `decodeIfPresent`，读到 nil——老现场照样能恢复，只是目录回到登录目录。
    public var remoteDirectory: String?

    public init(label: String, target: SSHTarget, remoteDirectory: String? = nil) {
        self.label = label
        self.host = target.host
        self.port = target.port
        self.username = target.username
        self.identityFilePath = target.identityFilePath
        self.jumpHost = target.jumpHost
        self.remoteDirectory = remoteDirectory
    }

    /// 还原成可连接的 `SSHTarget`。非法值（空 host 等）返回 nil ——
    /// 配置文件被人手改坏时不能把一批坏参数喂给 ssh。
    public var target: SSHTarget? {
        let target = SSHTarget(
            host: host,
            port: port,
            username: username,
            identityFilePath: identityFilePath,
            jumpHost: jumpHost
        )
        return target.validationErrors().isEmpty ? target : nil
    }
}

/// 终端现场的持久化（标签组合 + 每个标签的 ssh 目标）。
///
/// 存在 `~/Library/Application Support/CogniTerm/terminal-workspace.json`，
/// 与 dsh 的会话记录分开（那是 agent 的，这是终端的）。
///
/// fail-soft：文件坏了就当"没有上次现场"，绝不让 App 起不来。
public enum TerminalWorkspaceStore {

    public struct Snapshot: Codable, Equatable, Sendable {
        /// 写入时间，仅用于诊断（"这份现场是什么时候的"）。
        public var savedAt: Date
        public var tabs: [StoredTerminalTab]

        public init(savedAt: Date = Date(), tabs: [StoredTerminalTab]) {
            self.savedAt = savedAt
            self.tabs = tabs
        }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CogniTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("terminal-workspace.json")
    }

    public static func load(from url: URL = defaultFileURL()) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }

    public static func save(_ snapshot: Snapshot, to url: URL = defaultFileURL()) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
