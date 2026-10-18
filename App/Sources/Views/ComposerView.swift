import SwiftUI
import AcpClient

struct ComposerView: View {
    @ObservedObject var sidecar: SidecarService
    @ObservedObject var conversation: ConversationModel
    @ObservedObject private var quoteStore = TerminalQuoteStore.shared
    @State private var draft: String = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 6) {
            // 终端选区引用 chip：一眼能看出「这次带着终端上下文问」，
            // × 可整块丢弃。引用块在发送时才拼进 prompt（见 send()）。
            if quoteStore.hasQuote {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .font(.caption2)
                    Text("已引用终端选区（\(quoteStore.quoteLineCount) 行）")
                        .font(.caption2)
                    Spacer(minLength: 4)
                    Button {
                        quoteStore.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("丢弃这段引用")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.10), in: Capsule())
                .padding(.horizontal, 8)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text(placeholder)
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                            .padding(.top, 6)
                    }
                    TextEditor(text: $draft)
                        .font(.body)
                        .frame(height: 64)
                        .disabled(!canSend)
                }
                if conversation.isWorking {
                    // 中断当前轮次（session/cancel）。
                    Button {
                        Task { await sidecar.cancelCurrent() }
                    } label: {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("中断当前轮次（session/cancel）")
                }
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!canSend || sending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(8)

            if let usage = conversation.usage {
                HStack {
                    Spacer()
                    Text("上下文 \(Self.format(usage.used)) / \(Self.format(usage.size)) tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var canSend: Bool {
        if case .ready = sidecar.status { return true }
        return false
    }

    /// 有引用时 placeholder 换成引导语——用户带着终端输出进来，
    /// 下一步大概率是「这段什么意思 / 怎么修」。
    private var placeholder: String {
        if quoteStore.hasQuote {
            return "问这段终端输出什么（⌘↵ 发送）"
        }
        return "给 dsh 发指令，⌘↵ 发送"
    }

    private static func format(_ value: Int64) -> String {
        if value >= 1000 {
            return String(format: "%.1fk", Double(value) / 1000)
        }
        return String(value)
    }

    private func send() {
        var text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 引用块拼在问题前面：fence 包裹让 agent 知道这是终端原文而非用户的话。
        if let quote = quoteStore.quote {
            text = "终端输出（引用）：\n```\n\(quote)\n```\n\n\(text)"
            quoteStore.clear()
        }
        guard canSend, !text.isEmpty, let sessionID = sidecar.sessionID else { return }
        draft = ""
        sending = true

        Task {
            conversation.appendUser(text)
            conversation.setWorking(true)
            do {
                let result = try await sidecar.client?.prompt(sessionId: sessionID, text: text)
                if let result {
                    conversation.handlePromptResult(result)
                } else {
                    conversation.setWorking(false)
                }
            } catch {
                conversation.appendSystem("prompt 失败：\(error)")
                conversation.setWorking(false)
            }
            sending = false
        }
    }
}
