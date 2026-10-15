import SwiftUI
import AcpClient

struct ComposerView: View {
    @ObservedObject var sidecar: SidecarService
    @ObservedObject var conversation: ConversationModel
    @State private var draft: String = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("给 dsh 发指令，⌘↵ 发送")
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
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(!canSend || sending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(8)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var canSend: Bool {
        if case .ready = sidecar.status { return true }
        return false
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
