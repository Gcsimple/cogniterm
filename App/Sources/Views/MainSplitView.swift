import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftData
import AcpClient
import PolicyEngine
import Persistence
import SessionLogReader

struct MainSplitView: View {
    @StateObject private var sidecar = SidecarService()
    @StateObject private var conversation = ConversationModel()
    @StateObject private var terminalBridge = TerminalBridge()

    @Environment(\.modelContext) private var modelContext
    @State private var workspacePath: String = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var showDiagnostics = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            detail
        }
        .task {
            sidecar.conversation = conversation
            conversation.workspaceRoot = workspacePath
            loadRules()
            terminalBridge.start()
            // 零配置：自动播种 profile，有 Key 直连，无 Key 弹一次引导。
            await sidecar.bootstrap()
        }
        .sheet(isPresented: $sidecar.needsOnboarding) {
            OnboardingView(sidecar: sidecar)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Sidecar") {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(sidecar.status.label)
                        .font(.caption)
                        .lineLimit(2)
                }
                Text(sidecar.serverInfo)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                switch sidecar.status {
                case .needsKey:
                    Button {
                        sidecar.needsOnboarding = true
                    } label: {
                        Label("设置 API Key…", systemImage: "key")
                    }
                case .failed, .stopped:
                    Button {
                        applyWorkspace()
                        Task { await sidecar.bootstrap() }
                    } label: {
                        Label("重新连接", systemImage: "arrow.clockwise")
                    }
                case .starting, .ready:
                    Button(role: .destructive) {
                        Task { await sidecar.stop() }
                    } label: {
                        Label("断开", systemImage: "stop.circle")
                    }
                    .disabled(sidecar.status == .starting)
                }

                Button {
                    applyWorkspace()
                    Task { await sidecar.enterDemo() }
                } label: {
                    Label("演示模式", systemImage: "wand.and.stars")
                }
                .font(.caption)
                .disabled(isBusy)
            }

            Section("工作区") {
                TextField("绝对路径", text: $workspacePath)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit(applyWorkspace)
                Button("选择文件夹…") { chooseWorkspace() }
                    .font(.caption)
            }

            Section("JSONL 轨迹") {
                Button("读取 JSONL 并回放条数…") { chooseAndInspectJSONL() }
                    .font(.caption)
            }

            Section {
                Toggle("诊断输出", isOn: $showDiagnostics)
                if showDiagnostics {
                    ScrollView {
                        Text(sidecar.diagnostics.joined(separator: "\n"))
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                }
            } header: {
                Text("诊断")
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    private var detail: some View {
        VSplitView {
            VStack(spacing: 0) {
                TrajectoryView(conversation: conversation)
                if let pending = conversation.pendingPermission {
                    ApprovalCardView(
                        pending: pending,
                        workspaceRoot: conversation.workspaceRoot,
                        onRespond: { conversation.respond($0) },
                        onRemember: rememberRule
                    )
                }
                Divider()
                ComposerView(sidecar: sidecar, conversation: conversation)
            }
            .frame(minHeight: 320)

            TerminalPanel(bridge: terminalBridge)
                .frame(minHeight: 140)
        }
    }

    // MARK: - 操作

    private var isBusy: Bool {
        switch sidecar.status {
        case .starting, .ready: true
        default: false
        }
    }

    private var statusColor: Color {
        switch sidecar.status {
        case .ready: return .green
        case .starting: return .orange
        case .failed: return .red
        case .stopped: return .secondary
        case .needsKey: return .yellow
        }
    }

    private func applyWorkspace() {
        let standardized = URL(fileURLWithPath: workspacePath).standardizedFileURL.path
        workspacePath = standardized
        sidecar.workspaceRoot = URL(fileURLWithPath: standardized)
        conversation.workspaceRoot = standardized
        // 已连接时切换工作区需要用新 cwd 重建会话。
        if case .ready = sidecar.status {
            Task {
                await sidecar.stop()
                await sidecar.start()
            }
        }
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            workspacePath = url.path
            applyWorkspace()
        }
    }

    private func chooseAndInspectJSONL() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.title = "选择 dsh 会话 JSONL 轨迹"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let events = try JSONLFile.readAll(at: url)
            let kinds = Dictionary(grouping: events.map(\.kind), by: { $0 })
                .map { "\($0.key):\($0.value.count)" }
                .sorted()
                .joined(separator: "，")
            conversation.appendSystem("JSONL 读取成功：\(events.count) 条事件（\(kinds)）")
        } catch {
            conversation.appendSystem("JSONL 读取失败：\(error)")
        }
    }

    private func loadRules() {
        let descriptor = FetchDescriptor<ApprovalRuleRecord>()
        let records = (try? modelContext.fetch(descriptor)) ?? []
        conversation.ruleSet = RuleSet(rules: records.map(\.asPolicyRule))
    }

    private func rememberRule(_ rule: PolicyEngine.ApprovalRule) {
        modelContext.insert(ApprovalRuleRecord(rule))
        try? modelContext.save()
        loadRules()
    }
}
