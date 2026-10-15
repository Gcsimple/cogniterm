import SwiftUI
import AppKit

/// 首次启动引导：唯一需要用户做的事——填一次 DeepSeek API Key（存 Keychain，之后自动连接）。
/// 不想填也可以先进入演示模式。
struct OnboardingView: View {
    @ObservedObject var sidecar: SidecarService

    @State private var apiKey: String = ""
    @State private var showKey = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)

            Text("欢迎使用 CogniTerm")
                .font(.title2.bold())

            Text("AI 终端已就绪。只需填写一次 DeepSeek API Key，它将保存在本机 Keychain 中，之后启动会自动连接。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if showKey {
                    TextField("sk-…", text: $apiKey)
                } else {
                    SecureField("sk-…", text: $apiKey)
                }
                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showKey ? "隐藏" : "显示")
            }
            .frame(width: 360)
            .onSubmit(connect)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button("获取 API Key") {
                    if let url = URL(string: "https://platform.deepseek.com/api_keys") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Spacer()
                Button("先进入演示模式") {
                    Task { await sidecar.enterDemo() }
                }
                Button("保存并开始") {
                    connect()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .frame(width: 360)
        }
        .padding(28)
        .frame(width: 440)
    }

    private func connect() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("sk-") else {
            errorMessage = "Key 格式似乎不正确（通常以 sk- 开头），请检查后重试。"
            return
        }
        errorMessage = nil
        Task { await sidecar.saveKeyAndConnect(trimmed) }
    }
}
