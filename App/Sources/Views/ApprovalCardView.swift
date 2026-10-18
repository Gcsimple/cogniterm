import SwiftUI
import AcpClient
import PolicyEngine
import Persistence

/// 原生审批卡：展示工具调用、风险标签与工作区边界，用户显式选择后才应答 ACP。
/// 命令文本来自 ToolCallTracker 补给的快照（dsh 0.2 审批请求只带 toolCallId）。
struct ApprovalCardView: View {
    let pending: ConversationModel.PendingPermission
    let workspaceRoot: String?
    var onRespond: (PermissionResponse) -> Void
    var onRemember: (ApprovalRule) -> Void
    /// 「在终端运行」出口：命令注入我们的 PTY 执行、输出回喂 agent。
    /// 与「允许」互斥——选了它就是对 ACP 回 reject（见 respondRunInTerminal）。
    var onRunInTerminal: (String) -> Void = { _ in }

    @State private var rememberRule = false

    private var command: String {
        pending.commandText
    }

    private var hasCommandText: Bool {
        pending.hasCommandText
    }

    private var risk: RiskAssessment {
        // 风险判定只基于真实命令文本；仅有 toolCallId 时不做模式猜测。
        RiskEvaluator.assess(.init(
            tool: pending.toolName,
            command: hasCommandText ? command : "",
            cwd: workspaceRoot,
            workspaceRoot: workspaceRoot
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(.orange)
                Text(pending.params.toolCall.title ?? "工具调用请求（等待审批）")
                    .font(.headline)
                Spacer()
                ForEach(risk.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15), in: Capsule())
                }
            }

            // 工具名 + 命令（关联失败时命令区退化显示工具标识）。
            Text(pending.toolName)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            if let snapshot = pending.snapshot, let path = snapshot.locations.first?.path {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Toggle("始终允许该命令（仅限本工作区）", isOn: $rememberRule)
                    .font(.caption)
                    .disabled(!hasCommandText)
                Spacer()
                Button("取消") { respond(cancel: true) }
                    .keyboardShortcut(.cancelAction)
                Button("拒绝") { respond(cancel: false, allow: false) }
                    .keyboardShortcut("r", modifiers: .command)
                // 「在终端运行」：拒绝 agent 直接执行，命令进用户的终端
                // （可见、可 Ctrl-C），输出收敛后自动回喂。
                Button("在终端运行") { onRunInTerminal(command) }
                    .keyboardShortcut("t", modifiers: .command)
                    .disabled(!hasCommandText)
                    .help("拒绝 agent 直接执行；命令改在你的终端里运行，输出自动回喂给它")
                Button("允许") { respond(cancel: false, allow: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func respond(cancel: Bool, allow: Bool = false) {
        if !cancel, allow, rememberRule, hasCommandText {
            let rule = ApprovalRule(
                tool: pending.toolName,
                pattern: command,
                workspaceScoped: true
            )
            onRemember(rule)
        }
        if cancel {
            onRespond(.cancel())
        } else {
            // 用服务端本次广告的 optionId 应答，不能回硬编码 ID。
            onRespond(allow
                      ? pending.params.responseAllowing()
                      : pending.params.responseRejecting())
        }
    }
}

/// 终端命令审批卡：agent 通过 MCP `run_in_terminal` 申请在用户终端执行命令。
///
/// 与 ApprovalCardView 的分工：那边应答 ACP `session/request_permission`
/// （dsh 发起，选项 id 由服务端广告）；这边是 App 自己的门——MCP 工具在
/// dsh 侧不走审批（dsh-mcp-client 无审批逻辑、tools/pre-execute 默认 allow），
/// 所以"允许"之后由 App 注入 PTY 执行，输出作为 MCP 工具结果回给 agent。
/// 两条路殊途同归：命令都在用户可见的终端里跑。
struct TerminalCommandCard: View {
    let pending: ConversationModel.PendingTerminalCommand
    var onAllow: () -> Void
    var onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundStyle(.blue)
                Text("agent 请求在终端执行命令")
                    .font(.headline)
                Spacer()
                Text(TerminalMCP.toolName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12), in: Capsule())
            }

            Text(pending.command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            if let root = pending.workspaceRoot {
                Text("工作目录：\(root)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Text("允许后命令会注入你的终端执行（屏幕可见、可随时 Ctrl-C），输出自动回给 agent。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("取消") { onReject() }
                    .keyboardShortcut(.cancelAction)
                Button("拒绝") { onReject() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("允许执行") { onAllow() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
