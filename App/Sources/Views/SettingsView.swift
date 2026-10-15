import SwiftUI
import SwiftData
import Persistence

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @State private var apiKey: String = ""
    @State private var statusMessage: String?
    @State private var policyMode: PolicyMode = .strict
    @State private var sandboxMode: SandboxMode = .workspaceWrite
    @State private var telemetryEnabled = false

    private let keychain = KeychainService()

    var body: some View {
        Form {
            Section("DeepSeek API Key") {
                SecureField("DEEPSEEK_API_KEY", text: $apiKey)
                HStack {
                    Button("存入 Keychain") { saveKey() }
                    Button("从 Keychain 删除") { clearKey() }
                    Spacer()
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Key 只在拉起 sidecar 时注入子进程环境，不写入 SwiftData，也不参与遥测。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("策略") {
                Picker("审批模式", selection: $policyMode) {
                    Text("严格（每次询问）").tag(PolicyMode.strict)
                    Text("规则（命中允许规则自动放行）").tag(PolicyMode.rules)
                    Text("闭关（一律拒绝）").tag(PolicyMode.closed)
                }
                Picker("Sidecar 沙箱", selection: $sandboxMode) {
                    Text("只读").tag(SandboxMode.readOnly)
                    Text("工作区可写").tag(SandboxMode.workspaceWrite)
                    Text("关闭").tag(SandboxMode.off)
                }
                Toggle("启用遥测（默认关闭）", isOn: $telemetryEnabled)
            }

            HStack {
                Spacer()
                Button("保存设置") { saveSettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear(perform: load)
    }

    private func load() {
        apiKey = keychain.read() ?? ""
        if let settings = try? modelContext.fetch(FetchDescriptor<AppSettings>()).first {
            policyMode = settings.policyMode
            sandboxMode = settings.sandboxMode
            telemetryEnabled = settings.telemetryEnabled
        }
    }

    private func saveKey() {
        do {
            try keychain.save(apiKey)
            statusMessage = "已保存，重新连接后生效"
        } catch {
            statusMessage = "保存失败：\(error)"
        }
    }

    private func clearKey() {
        keychain.clear()
        apiKey = ""
        statusMessage = "已删除"
    }

    private func saveSettings() {
        let settings = (try? modelContext.fetch(FetchDescriptor<AppSettings>()))?.first ?? AppSettings()
        settings.policyMode = policyMode
        settings.sandboxMode = sandboxMode
        settings.telemetryEnabled = telemetryEnabled
        modelContext.insert(settings)
        try? modelContext.save()
        statusMessage = "设置已保存"
    }
}
