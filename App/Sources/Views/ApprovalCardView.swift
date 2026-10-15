import SwiftUI
import AcpClient
import PolicyEngine
import Persistence

/// 原生审批卡：展示工具调用、风险标签与工作区边界，用户显式选择后才应答 ACP。
struct ApprovalCardView: View {
    let pending: ConversationModel.PendingPermission
    let workspaceRoot: String?
    var onRespond: (PermissionResponse) -> Void
    var onRemember: (ApprovalRule) -> Void

    @State private var rememberRule = false

    /// dsh 0.2 审批请求只带 toolCallId；命令文本缺省时展示调用标识。
    private var command: String {
        pending.params.toolCall.rawCommand
            ?? pending.params.toolCall.title
            ?? pending.params.toolCall.toolCallId
            ?? "未知工具调用"
    }

    private var hasCommandText: Bool {
        pending.params.toolCall.rawCommand != nil
    }

    private var risk: RiskAssessment {
        // 风险判定只基于真实命令文本；仅有 toolCallId 时不做模式猜测。
        RiskEvaluator.assess(.init(
            tool: pending.params.toolCall.kind ?? "bash",
            command: pending.params.toolCall.rawCommand ?? "",
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

            Text(command)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Toggle("始终允许该命令（仅限本工作区）", isOn: $rememberRule)
                    .font(.caption)
                    .disabled(!hasCommandText)
                Spacer()
                Button("取消") { respond(cancel: true) }
                    .keyboardShortcut(.cancelAction)
                Button("拒绝") { respond(cancel: false, allow: false) }
                    .keyboardShortcut("r", modifiers: .command)
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
                tool: pending.params.toolCall.kind ?? "bash",
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
