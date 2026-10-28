import Foundation

/// SSH 连接复用（`ControlMaster`）的 socket 路径。
///
/// ## 为什么这是「每次都要输密码」的第一解
///
/// 密码只在**建连**那一刻需要。复用一条已认证的通道之后，新标签页走的是
/// 同一根 TCP + 同一个已认证 session（ssh 的通道多路复用），既不重新认证、
/// 也不需要密码。好处是**完全不碰密码本身**：没有存储、没有注入、没有猜
/// 提示符的时机。
///
/// `ControlPersist=600` 让 master 在最后一个通道关掉后继续活 10 分钟——
/// 「关掉标签又马上重连」这种最常见的重复输入场景正好被吃掉。
public enum SSHConnectionSharing {

    /// ControlPath 的长度上限是 `sun_path`（macOS 上 104 字节，含结尾 NUL）。
    /// 超了就**不启用复用**，而不是截断——截断会让两个不同目标撞到同一个
    /// socket 上（等于把命令发到别的机器）。
    static let maxSocketPathLength = 100

    /// socket 文件名：`user@host:port` 的 FNV-1a 64 位摘要。
    ///
    /// 为什么不用 `Hasher` / `hashValue`：Swift 的哈希每次进程启动重新加盐，
    /// 重启后算出的名字就变了——socket 找不到，复用静默失效，而且**永远**
    /// 只会失效不会报错。
    public static func socketName(for target: SSHTarget) -> String {
        "ct-\(hexDigest(identityKey(for: target)))"
    }

    /// 同一份身份参数 → 同一个 socket。改用户名 / 端口就是**另一条**通道
    /// （不同账号的已认证 session 不能互相复用）。
    ///
    /// 同时被 Keychain 分账复用（见 `SSHPasswordStore.account(for:)`）：
    /// "同一个目标"必须是同一套判据，否则会出现"socket 复用了 A 的通道、
    /// 密码取的是 B 的"这种错配。
    public static func identityKey(for target: SSHTarget) -> String {
        "\(target.username ?? "")@\(target.host):\(target.port)"
    }

    /// 完整路径。目录由调用方给（纯层不碰文件系统）；路径过长时返回 nil。
    public static func socketPath(for target: SSHTarget, directory: String) -> String? {
        var base = directory
        while base.count > 1 && base.hasSuffix("/") { base.removeLast() }
        let path = base + "/" + socketName(for: target)
        guard path.utf8.count <= maxSocketPathLength else { return nil }
        return path
    }

    /// 每个目标一个 16 位十六进制摘要（64 位），碰撞概率对我们这个量级无意义。
    static func hexDigest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

/// 识别「ssh 正停在密码提示上」。
///
/// ## 为什么需要它，以及为什么这么保守
///
/// 用户选了「保存密码」之后，App 要在**正确的那一屏**把密码写进 PTY。
/// 判错的代价是把明文密码打进终端（可能落进 scrollback、被 `cat` 的内容
/// 掩盖、甚至被后来的命令当参数），所以这里只认 ssh 自己那两种固定形态：
///
/// - `deploy@host's password:`
/// - `Password for deploy@host:`
///
/// **故意不**泛化匹配 `password:`——`cat` 一个含该字样的文件也会命中，
/// 而那一刻填密码是灾难性的。宁可漏判（用户手输一次），不可错判。
public struct PasswordPromptDetector: Sendable {

    /// 只保留末尾这么多个字节。密码提示永远在屏幕最后一行，更早的内容
    /// 只会增加误判面。
    private static let maxTail = 256

    private var tail: [UInt8] = []

    public init() {}

    /// 喂入一段 PTY 输出；返回 true 表示当前这一屏停在密码提示上。
    @discardableResult
    public mutating func feed(_ data: Data) -> Bool {
        tail.append(contentsOf: data)
        if tail.count > Self.maxTail {
            tail.removeFirst(tail.count - Self.maxTail)
        }
        return isAtPasswordPrompt
    }

    /// 当前缓冲是否停在密码提示。
    public var isAtPasswordPrompt: Bool {
        // 提示符后面可能跟一个空格或 \r（ssh 用 `\r` 把它刷在最左）。
        guard let text = String(bytes: tail, encoding: .utf8) else { return false }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let lower = normalized.lowercased()
        if lower.hasSuffix("'s password:") { return true }
        if lower.hasSuffix(":"),
           let range = lower.range(of: "password for ", options: .backwards),
           lower.distance(from: range.lowerBound, to: lower.endIndex) <= 120 {
            return true
        }
        return false
    }

    /// 填过一次之后清空：同一次连接里不该再自动填（密码错了要让用户接手，
    /// 而不是拿错的密码去撞 max attempts）。
    public mutating func reset() {
        tail.removeAll()
    }
}
