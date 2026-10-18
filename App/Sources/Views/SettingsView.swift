import SwiftUI
import SwiftData
import Persistence

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var sidecar: SidecarService

    @State private var apiKey: String = ""
    @State private var statusMessage: String?
    @State private var policyMode: PolicyMode = .strict
    @State private var sandboxMode: SandboxMode = .workspaceWrite
    @State private var telemetryEnabled = false
    @State private var agentModel: AgentModel = .flash

    private let keychain = KeychainService()

    /// 模型展示名与说明。key 缺失时回落到 rawValue，不让 UI 空着。
    /// 取值与 `AgentModel` 的 wire id 一一对应，说明文案里的模型名用账号侧
    /// 的真实展示名（实测 `/v1/models`）。
    private static let modelLabel: [AgentModel: String] = [
        .flash: "Flash（快，日常默认）",
        .pro: "Pro（强推理，成本更高）",
    ]

    private static let modelHint: [AgentModel: String] = [
        .flash: "DeepSeek-V41-Flash（dsh 目录 id: deepseek-flash）。日常编码任务的默认档。",
        .pro: "DeepSeek-V4-Pro（dsh 目录 id: deepseek-v4-pro）。更强的 agentic 编码与困难推理，适合复杂或质量敏感的任务。",
    ]

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

            Section("模型") {
                Picker("默认模型", selection: $agentModel) {
                    ForEach(AgentModel.allCases, id: \.self) { model in
                        Text(Self.modelLabel[model] ?? model.rawValue).tag(model)
                    }
                }
                Text(Self.modelHint[agentModel] ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("这是**新会话的启动缺省值**：切换后需重连 sidecar 才生效（DSH_COGNITERM_MODEL 由启动环境注入，落点是 dsh profile 的 acp 行 + agent-default-model）。"
                     + "已经开着的会话请用左侧「会话配置」里的模型选择器实时切换。")
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
                    Text("关闭（danger-full-access）").tag(SandboxMode.off)
                }
                Toggle("启用遥测（默认关闭）", isOn: $telemetryEnabled)
                Text("审批模式立即生效；沙箱与遥测在下次连接 sidecar 时注入（DSH_PERMISSION_MODE / 补丁开关）。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("保存设置") { saveSettings() }
                    .buttonStyle(.borderedProminent)
                Button("保存并重连") {
                    saveSettings()
                    Task { await reconnect() }
                }
                .disabled(sidecar.status == .starting)
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
            agentModel = settings.agentModel
        }
        // 不触碰 sidecar.conversation：主窗口持有的会话引用必须保持有效，
        // 否则审批应答会因 weak 引用断裂而 fail-closed。
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
        settings.agentModel = agentModel
        modelContext.insert(settings)
        try? modelContext.save()
        sidecar.update(settings: .init(policyMode: policyMode,
                                       sandboxMode: sandboxMode,
                                       telemetryEnabled: telemetryEnabled,
                                       agentModel: agentModel))
        statusMessage = "设置已保存"
    }

    /// 停后用新设置重启 sidecar（沙箱/遥测在启动参数里生效）。
    private func reconnect() async {
        await sidecar.stop()
        if sidecar.hasAPIKey {
            await sidecar.start()
        } else {
            await sidecar.bootstrap()
        }
    }
}
