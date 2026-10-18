import SwiftUI

/// 会话轨迹（展示面）：用户输入 / 助手消息 / 工具调用 / 计划 / 系统提示。
struct TrajectoryView: View {
    @ObservedObject var conversation: ConversationModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if conversation.rows.isEmpty {
                        emptyState
                    }
                    ForEach(conversation.rows) { row in
                        RowView(row: row, conversation: conversation).id(row.id)
                    }
                    if conversation.isWorking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("sidecar 处理中…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("working-indicator")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: conversation.rows.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    if let last = conversation.rows.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    } else {
                        proxy.scrollTo("working-indicator", anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("开始一个会话")
                .font(.headline)
            Text("在下方输入指令；sidecar 每次需要授权时都会在这里弹出审批卡。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

private struct RowView: View {
    let row: TranscriptRow
    @ObservedObject var conversation: ConversationModel

    var body: some View {
        switch row.kind {
        case .user:
            bubble(Text(row.text).font(.body),
                   color: .accentColor.opacity(0.18),
                   alignment: .trailing)
        case .assistant:
            bubble(Text(row.text).font(.body),
                   color: Color(nsColor: .controlBackgroundColor),
                   alignment: .leading)
        case .tool:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.text).font(.system(.caption, design: .monospaced))
                        if let status = row.status {
                            Text(status)
                                .font(.caption2)
                                .foregroundStyle(statusColor(status))
                        }
                    }
                }
                // 完整输出：默认折叠（长结果不进对话流），按需展开。
                // 展开视图限高 200pt + 内部滚动——完整日志可能有几百行，
                // 不限制会把对话区彻底撑飞。
                if let full = row.fullResult, !full.isEmpty {
                    if conversation.isResultExpanded(row.id) {
                        ScrollView {
                            Text(full)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(6)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        Button("收起") { conversation.toggleResultExpansion(row.id) }
                            .font(.caption2)
                    } else {
                        Button("展开完整输出（\(full.split(separator: "\n", omittingEmptySubsequences: false).count) 行）") {
                            conversation.toggleResultExpansion(row.id)
                        }
                        .font(.caption2)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .plan:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "list.clipboard")
                    .font(.caption)
                    .foregroundStyle(.purple)
                    .padding(.top, 2)
                Text(row.text).font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case .system:
            Text(row.text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func bubble(_ content: some View, color: Color, alignment: HorizontalAlignment) -> some View {
        HStack {
            if alignment == .trailing { Spacer(minLength: 40) }
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(color, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 480, alignment: alignment == .trailing ? .trailing : .leading)
            if alignment == .leading { Spacer(minLength: 40) }
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
