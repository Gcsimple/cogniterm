import SwiftUI
import AppKit
import SwiftData
import Persistence
import TerminalCore

/// 新建 SSH 会话表单。
///
/// 校验走 `SSHTarget.validationErrors()`（纯层，可单测）；这里只负责把
/// 表单文本翻成 `SSHTarget`、落书签、开会话。**不保存任何凭据**：
/// 密码在终端里交互输入（ssh 自己提示），私钥与 passphrase 交给
/// ssh-agent / 系统钥匙串——这是 MobaXterm 之外另一条同样安全的路。
struct NewSSHSessionSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sessions = SessionManager.shared

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var identityPath = ""
    @State private var jumpHost = ""
    /// 远程执行目录（agent 的终端命令会在这里跑）。可选。
    @State private var remoteDirectory = ""
    /// 是否把密码存进 Keychain（默认否：不勾选时行为和从前完全一样）。
    @State private var rememberPassword = false
    @State private var password = ""
    /// 当前输入的目标是否已经存过密码（决定是否显示「清除」）。
    @State private var existingPassword = false
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("新建 SSH 会话")
                .font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("名称").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("可选，默认 user@host", text: $name)
                }
                GridRow {
                    Text("主机").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    TextField("example.com 或 10.0.0.5", text: $host)
                }
                GridRow {
                    Text("端口").foregroundStyle(.secondary)
                    TextField("22", text: $port)
                        .frame(width: 80)
                }
                GridRow {
                    Text("用户名").foregroundStyle(.secondary)
                    TextField("可选，默认当前用户", text: $username)
                }
                GridRow {
                    Text("私钥").foregroundStyle(.secondary)
                    HStack {
                        TextField("可选，如 ~/.ssh/id_ed25519", text: $identityPath)
                        Button("选择…") { chooseIdentityFile() }
                            .controlSize(.small)
                    }
                }
                GridRow {
                    Text("跳板").foregroundStyle(.secondary)
                    TextField("可选，如 ops@bastion", text: $jumpHost)
                }
                GridRow {
                    Text("远程目录").foregroundStyle(.secondary)
                    TextField("可选，agent 的命令在这里执行，如 /opt/app", text: $remoteDirectory)
                }
                GridRow {
                    Text("密码").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Toggle("保存密码到钥匙串，连接时自动填入", isOn: $rememberPassword)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        if rememberPassword {
                            SecureField(existingPassword
                                        ? "留空则沿用已保存的密码"
                                        : "登录密码（只写进 Keychain）",
                                        text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                        if existingPassword {
                            HStack(spacing: 6) {
                                Text("该主机已保存密码")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Button("清除") {
                                    SSHPasswordStore.removePassword(for: candidateTarget)
                                    existingPassword = false
                                }
                                .controlSize(.small)
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 说明只留「会影响用户怎么操作」的部分，三段落合成两行。
            // 这张表上用户真正要决定的只有两件事：存不存密码、远程目录填不填。
            // 通道复用那段的原文解释了 ControlMaster 机制——用户没法据此做任何
            // 决定，但"为什么这次没问密码"是会被问到的，所以压成一句留着。
            Text(rememberPassword
                 ? "只写进 macOS 钥匙串；连接时自动填一次，填错就交回你手输。"
                 : "密码在终端里提示输入；不勾这一项就不保存任何凭据。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("已连过的目标 10 分钟内复用连接，不会再问密码。"
                 + "远程目录只声明 agent 在哪执行，终端本身要跟过去请点工具栏的「同步目录」。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("连接") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        // 目标一变就去问一次 Keychain（不逐键查：既没必要，也会反复触发
        // 钥匙串的访问授权）。
        .onChange(of: candidateKey) { _, _ in refreshExistingPassword() }
        .task { refreshExistingPassword() }
    }

    // MARK: - 动作

    /// 表单当前填出来的目标（可能还不合法）。密码存取按它分账。
    private var candidateTarget: SSHTarget {
        SSHTarget(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            identityFilePath: identityPath.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            jumpHost: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
    }

    /// 目标三元组（原始文本）。用它做 `onChange` 的判据比用整个 `SSHTarget`
    /// 稳：私钥/跳板改了不影响密码归属，不该触发一次 Keychain 查询。
    private var candidateKey: String {
        "\(username)@\(host):\(port)"
    }

    private func refreshExistingPassword() {
        let target = candidateTarget
        existingPassword = target.isValid && SSHPasswordStore.hasPassword(for: target)
    }

    private func connect() {
        let target = candidateTarget
        let errors = target.validationErrors()
        guard errors.isEmpty else {
            errorText = errors.joined(separator: "；")
            return
        }
        // 只有勾了才写 Keychain。**取消勾选不等于删除**——删除是那个明写的
        // 「清除」按钮，避免"这次不想自动填"顺手把密码弄丢。
        if rememberPassword, !password.isEmpty {
            guard SSHPasswordStore.save(password, for: target) else {
                errorText = "密码没能写进钥匙串（可能被锁或授权被拒）。"
                         + "取消勾选后可以直接连接，密码会在终端里提示输入。"
                return
            }
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? target.displayName
        upsertBookmark(target: target, label: label)
        sessions.openSSHSession(
            target: target,
            label: label,
            root: FileManager.default.homeDirectoryForCurrentUser,
            remoteDirectory: remoteDirectory.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        dismiss()
    }

    /// 同 host+port+user 视为同一书签（重复连接不堆重复条目）。
    private func upsertBookmark(target: SSHTarget, label: String) {
        let host = target.host
        let port = target.port
        let user = target.username ?? ""
        let descriptor = FetchDescriptor<SSHBookmark>(
            predicate: #Predicate { $0.host == host && $0.port == port && $0.username == user }
        )
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.name = label
            existing.identityFilePath = target.identityFilePath
            existing.jumpHost = target.jumpHost
            existing.lastUsedAt = Date()
        } else {
            modelContext.insert(SSHBookmark(
                name: label,
                host: target.host,
                port: target.port,
                username: target.username ?? "",
                identityFilePath: target.identityFilePath,
                jumpHost: target.jumpHost,
                lastUsedAt: Date()
            ))
        }
        try? modelContext.save()
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.message = "选择私钥文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        identityPath = url.path
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
