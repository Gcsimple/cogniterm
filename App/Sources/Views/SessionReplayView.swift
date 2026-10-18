import SwiftUI
import SessionLogReader

/// JSONL 回放弹窗的 Identifiable 包装（SessionViewState 是值类型）。
struct ReplayItem: Identifiable {
    let id = UUID()
    let state: SessionViewState
    let title: String
}

/// 把 dsh 会话 JSONL 经 SessionReducer 归约后的状态回放为可读会话。
/// 富内容真相源仍是 JSONL 文件本身；这里是归约视图。
struct SessionReplayView: View {
    let state: SessionViewState
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                statusBadge
            }
            .padding(12)

            Divider()

            List {
                if !state.plan.isEmpty {
                    Section("计划") {
                        ForEach(Array(state.plan.enumerated()), id: \.offset) { _, entry in
                            LabeledContent(entry.status) {
                                Text(entry.title)
                                    .font(.callout)
                            }
                        }
                    }
                }

                if !state.messages.isEmpty {
                    Section("消息（\(state.messages.count)）") {
                        ForEach(state.messages, id: \.id) { message in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(roleLabel(message.role))
                                    .font(.caption2.bold())
                                    .foregroundStyle(roleColor(message.role))
                                Text(message.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !state.toolCalls.isEmpty {
                    Section("工具调用（\(state.toolCalls.count)）") {
                        ForEach(state.toolCalls, id: \.id) { call in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(call.title ?? call.id)
                                    .font(.system(.callout, design: .monospaced))
                                HStack(spacing: 8) {
                                    if let status = call.status {
                                        Text(status)
                                            .font(.caption2)
                                            .foregroundStyle(statusColor(status))
                                    }
                                    if let command = call.command {
                                        Text(command)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    if let path = call.path {
                                        Text(path)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if let stopReason = state.stopReason {
                    Section("结束") {
                        LabeledContent("stopReason", value: stopReason)
                    }
                }
                if let error = state.lastError {
                    Section("错误") {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 480)
    }

    private var statusBadge: some View {
        Text(state.status.rawValue)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private func roleLabel(_ role: String) -> String {
        switch role {
        case "user": return "用户"
        case "assistant": return "助手"
        case "reasoning": return "推理"
        default: return role
        }
    }

    private func roleColor(_ role: String) -> Color {
        switch role {
        case "user": return .accentColor
        case "assistant": return .primary
        case "reasoning": return .secondary
        default: return .primary
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "completed", "allowed": return .green
        case "rejected", "failed", "error": return .red
        default: return .secondary
        }
    }
}
