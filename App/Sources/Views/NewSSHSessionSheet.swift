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
            }
            .textFieldStyle(.roundedBorder)

            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("密码在终端里交互输入；私钥口令走 ssh-agent。CogniTerm 不保存凭据。")
                .font(.caption2)
                .foregroundStyle(.secondary)

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
    }

    // MARK: - 动作

    private func connect() {
        let target = SSHTarget(
            host: host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            identityFilePath: identityPath.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            jumpHost: jumpHost.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        let errors = target.validationErrors()
        guard errors.isEmpty else {
            errorText = errors.joined(separator: "；")
            return
        }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? target.displayName
        upsertBookmark(target: target, label: label)
        sessions.openSSHSession(
            target: target,
            label: label,
            root: FileManager.default.homeDirectoryForCurrentUser
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
