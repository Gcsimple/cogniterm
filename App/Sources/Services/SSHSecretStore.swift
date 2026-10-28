import Foundation
import TerminalCore

/// SSH 登录密码的 Keychain 存取（按 `user@host:port` 分账）。
///
/// ## 默认不保存
///
/// 这个 App 原本的立场是「不保存任何凭据」（见 `NewSSHSessionSheet` 的注释）。
/// 但那条立场解决的是「我们不想替用户保管密码」，代价是**每次开标签都要手输**——
/// 而多数人的远程主机只开了密码认证，公钥没配。所以现在给一个显式选择：
///
/// - 不勾「保存密码」→ 行为和从前完全一样，密码只在终端里交互输入；
/// - 勾了 → 写进 Keychain（不是配置文件、不是日志），连接时自动填一次；
/// - 已保存后又取消勾选并连接 → **删除**该目标的密码。
///
/// 密码放在 `kSecClassGenericPassword` 里，account 用目标的三元组区分——同一个
/// host 不同用户名的密码是两回事。
enum SSHPasswordStore {

    static func account(for target: SSHTarget) -> String {
        "ssh-password:" + SSHConnectionSharing.identityKey(for: target)
    }

    static func password(for target: SSHTarget) -> String? {
        let value = KeychainService(account: account(for: target)).read()
        // 空串等同于"没存"：留空表示沿用已有的，不该被当成一个空密码。
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func hasPassword(for target: SSHTarget) -> Bool {
        password(for: target) != nil
    }

    /// 存密码。返回是否成功——Keychain 被锁 / 被拒时不静默失败，让调用方
    /// 能在界面上说一句"密码没存上"。
    @discardableResult
    static func save(_ password: String, for target: SSHTarget) -> Bool {
        guard !password.isEmpty else { return false }
        return (try? KeychainService(account: account(for: target)).save(password)) != nil
    }

    static func removePassword(for target: SSHTarget) {
        _ = KeychainService(account: account(for: target)).clear()
    }
}

/// `ControlMaster` 复用 socket 的目录。
///
/// 为什么不在 `~/.ssh/` 下：那是用户自己的目录，App 往里塞 unix socket 会
/// 混进 `ls ~/.ssh` 的结果，而且用户清理 ssh 配置时容易顺手删掉正在用的通道。
/// 用 App 自己的目录（0700），删除也无副作用——下次自然重建。
enum SSHControlDirectory {

    /// `~/.cogniterm/control`。每次访问都确保存在（幂等）。
    static var path: String {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cogniterm", isDirectory: true)
            .appendingPathComponent("control", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return base.path
    }
}
