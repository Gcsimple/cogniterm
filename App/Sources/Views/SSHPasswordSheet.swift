import SwiftUI
import TerminalCore

/// 给一个**已经开着的** SSH 会话设置 / 清除保存的登录密码。
///
/// 为什么需要这个入口（而不是只在新建表单里加密码框）：书签打开会话走的是
/// `TerminalTabBar.open → openSSHSession`，根本不过表单。只有在终端上再给一个
/// 入口，用户才不会"第一次没填密码就永远填不了"。
struct SSHPasswordSheet: View {
    @ObservedObject var session: TerminalSession

    @Environment(\.dismiss) private var dismiss

    @State private var usePassword: Bool
    @State private var password = ""
    @State private var errorText: String?

    init(session: TerminalSession) {
        self.session = session
        _usePassword = State(initialValue: session.savedPassword != nil)
    }

    private var target: SSHTarget? { session.sshTarget }

    /// 这个目标在 Keychain 里是否已经有密码（可能是别的会话存的）。
    private var storedOnDisk: Bool {
        guard let target else { return false }
        return SSHPasswordStore.hasPassword(for: target)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("登录密码")
                    .font(.headline)
                HStack(spacing: 4) {
                    Image(systemName: "network").font(.caption2)
                    Text(session.label).font(.caption2).lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }

            Toggle("保存密码，连接时自动填入", isOn: $usePassword)
                .toggleStyle(.checkbox)

            if usePassword {
                SecureField(storedOnDisk ? "留空则保留已保存的密码" : "登录密码（只写进 Keychain）",
                            text: $password)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(statusLine)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // ⚠️ 这里不要写 `**粗体**`：statusLine 是 String（不是字面量），
            // 走 `Text(_: StringProtocol)` 重载，markdown 不解析，星号会原样显示。
            Text("只写进 macOS 钥匙串；填错一次就交回你手输，不会反复重试撞锁定。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { apply(restart: false) }
                Button("保存并重连") { apply(restart: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    /// 当前状态的一行反馈。四个分支互斥，用户一次只看到一条。
    ///
    /// 不复述输入框 placeholder 已经说过的「留空沿用、填写覆盖」——
    /// 同一件事写两遍，界面上就成了噪音。
    private var statusLine: String {
        if usePassword {
            return storedOnDisk
                ? "下次连接自动填入；留空不改动已存的密码。"
                : "保存后，下次连接出现密码提示时会自动填入。"
        }
        return storedOnDisk
            ? "保存后会删除这把密码。"     // 不能说成"取消勾选即删除"，那是两个动作
            : "当前未保存密码：每次连接都在终端里手动输入。"
    }

    private func apply(restart: Bool) {
        guard let target else {
            errorText = "这个会话没有远端目标（不应该是 SSH 会话）"
            return
        }
        if usePassword {
            if !password.isEmpty {
                guard SSHPasswordStore.save(password, for: target) else {
                    errorText = "密码没能写进钥匙串（可能被锁或授权被拒）"
                    return
                }
                session.setSavedPassword(password)
            } else if !storedOnDisk {
                errorText = "没有输入密码，也没有已保存的密码"
                return
            } else {
                // 沿用 Keychain 里已有的值，把它读进内存。
                session.setSavedPassword(SSHPasswordStore.password(for: target))
            }
        } else {
            SSHPasswordStore.removePassword(for: target)
            session.setSavedPassword(nil)
        }
        if restart { session.restart() }
        dismiss()
    }
}
