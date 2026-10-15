import Foundation
import Combine
import AcpClient

/// Sidecar 生命周期与 ACP 连接的 App 层服务。
/// 真实模式：sandbox-exec(sidecar.sb) + node + dsh lib/bin.js --profile acp（--patch 关日志）。
/// 演示模式：LoopbackTransport + DemoPeer，无 runtime/API Key 也能走完整 UI/协议链路。
@MainActor
final class SidecarService: ObservableObject {
    enum Status: Equatable {
        case stopped
        case starting
        case ready
        case needsKey
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "未连接"
            case .starting: return "启动中…"
            case .ready: return "已连接"
            case .needsKey: return "需要 API Key（首次使用）"
            case .failed(let reason): return "连接失败：\(reason)"
            }
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var serverInfo: String = "未连接"
    @Published private(set) var sessionID: String?
    /// 首次使用且 Keychain 无 Key 时置真，驱动 Onboarding 弹窗。
    @Published var needsOnboarding: Bool = false
    @Published var diagnostics: [String] = []

    /// 在 start 前由界面注入。
    weak var conversation: ConversationModel?

    let broker = PermissionBroker()

    private(set) var client: DshAcpClient?
    private var supervisor: SidecarSupervisor?
    private var notificationTask: Task<Void, Never>?
    private let keychain = KeychainService()

    var workspaceRoot: URL = FileManager.default.homeDirectoryForCurrentUser

    // MARK: - runtime 布局
    //
    // 发布形态：node + dsh 随 App 内置在 Contents/Resources/runtime（构建期 vendor），
    // 用户零安装。开发/调试态可回退到 Application Support/CogniTerm/runtime。

    private var applicationSupportDirectory: URL {
        (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
    }

    private var installedRuntimeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("CogniTerm/runtime", isDirectory: true)
    }

    /// dsh 用户态 HOME（profiles / 日志 / session JSONL），首启时由 dsh 自行初始化。
    private var dshHomeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("CogniTerm/dsh-home", isDirectory: true)
    }

    private func isRuntimeUsable(_ dir: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("node-darwin-arm64/bin/node").path)
        && FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js").path)
    }

    private var bundledRuntimeDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("runtime", isDirectory: true)
        return isRuntimeUsable(dir) ? dir : nil
    }

    /// 当前实际使用的 runtime（内置优先）。
    private var runtimeDirectory: URL {
        bundledRuntimeDirectory ?? installedRuntimeDirectory
    }

    var isRuntimeAvailable: Bool {
        isRuntimeUsable(runtimeDirectory)
    }

    var hasAPIKey: Bool {
        guard let key = keychain.read() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var nodeURL: URL {
        runtimeDirectory.appendingPathComponent("node-darwin-arm64/bin/node")
    }

    private var cliURL: URL {
        runtimeDirectory.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
    }

    /// 包内隐私补丁（关闭随模型请求上报的会话日志）。dsh 首次启动会自行初始化
    /// $DSH_HOME/profiles/acp，无需 App 播种；补丁通过官方 --patch 覆盖层直接生效。
    private var noTelemetryPatchURL: URL? {
        let candidates = [
            Bundle.main.url(forResource: "no-telemetry", withExtension: "yml"),
            Bundle.main.url(forResource: "no-telemetry", withExtension: "yml", subdirectory: "patches"),
            Bundle.main.resourceURL?.appendingPathComponent("patches/no-telemetry.yml"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 零配置启动

    /// App 首启入口：dsh 首启自行初始化 profile；有 Key 直连，无 Key 弹一次 Onboarding。
    func bootstrap() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: dshHomeDirectory, withIntermediateDirectories: true)
        if hasAPIKey {
            await start()
        } else {
            status = .needsKey
            needsOnboarding = true
        }
    }

    /// Onboarding/设置页保存 Key 后立即连接。
    func saveKeyAndConnect(_ key: String) async {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try keychain.save(trimmed)
        } catch {
            status = .failed("Keychain 写入失败：\(error)")
            return
        }
        needsOnboarding = false
        await start()
    }

    func enterDemo() async {
        needsOnboarding = false
        await startDemo()
    }

    /// 沙箱描述文件必须存在；缺失即视为部署不完整（fail-closed，绝不裸连）。
    private func requireSandboxProfile() throws -> URL {
        if let url = Bundle.main.url(forResource: "sidecar",
                                    withExtension: "sb",
                                    subdirectory: "sandbox") {
            return url
        }
        if let url = Bundle.main.url(forResource: "sidecar", withExtension: "sb") {
            return url
        }
        struct ProfileMissing: Error {}
        throw ProfileMissing()
    }

    // MARK: - 真实 runtime

    func start() async {
        guard !isBusy else { return }

        guard hasAPIKey else {
            status = .needsKey
            needsOnboarding = true
            return
        }

        guard FileManager.default.isExecutableFile(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: cliURL.path) else {
            status = .failed("内置运行环境缺失，请重新安装完整版本的 CogniTerm")
            diagnostics.append("[launcher] 期望 Node：\(nodeURL.path)")
            diagnostics.append("[launcher] 期望 CLI：\(cliURL.path)")
            return
        }

        if let conversation {
            await broker.setAnswerer(conversation.makeAnswerer())
        }

        // 外层 seatbelt 粗墙（网络白名单 / ~/.ssh / Keychain 拒绝）；
        // 描述文件缺失即 fail-closed，绝不裸连。
        let profile: URL
        do {
            profile = try requireSandboxProfile()
        } catch {
            status = .failed("缺少 sidecar.sb 沙箱描述文件，已拒绝在无外层沙箱情况下启动")
            return
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        var arguments = [
            "-f", profile.path,
            "-D", "WORKSPACE_ROOT=\(workspaceRoot.standardizedFileURL.path)",
            "-D", "HOME_DIR=\(home)",
            "-D", "HOME_SSH=\(home)/.ssh",
            "-D", "HOME_GNUPG=\(home)/.gnupg",
            "-D", "HOME_KEYCHAINS=\(home)/Library/Keychains",
            // 凭据墙的完整字面路径（SBPL 双参 literal 在 macOS 27 会误匹配 $HOME 本身）。
            "-D", "AWS_CREDS=\(home)/.aws/credentials",
            "-D", "NETRC=\(home)/.netrc",
            // 写授权目录同样必须单参注入完整路径（双参 subpath 会误匹配 $HOME）。
            "-D", "NPM_CACHE_DIR=\(home)/.npm",
            "-D", "USER_CACHE_DIR=\(home)/.cache",
            "-D", "USER_LOGS_DIR=\(home)/Library/Logs",
            "-D", "APP_SUPPORT_COGNITERM=\(home)/Library/Application Support/CogniTerm",
            "-D", "RUNTIME_DIR=\(runtimeDirectory.path)",
            nodeURL.path, cliURL.path, "--profile", "acp",
        ]
        if let patch = noTelemetryPatchURL {
            arguments += ["--patch", patch.path]
        } else {
            diagnostics.append("[launcher] 警告：未找到包内 no-telemetry.yml，仅靠 DSH_TELEMETRY_DISABLED 兜底")
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(runtimeDirectory.path)/node-darwin-arm64/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["DEEPSEEK_API_KEY"] = keychain.read() ?? ""
        environment["DSH_TELEMETRY_DISABLED"] = "1"
        environment["NODE_NO_WARNINGS"] = "1"
        // dsh 用户态目录：profiles 补丁/会话记录全部落在 Application Support，随包只读。
        environment["DSH_HOME"] = dshHomeDirectory.path

        let config = SidecarConfig(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: workspaceRoot
        )

        let supervisor = SidecarSupervisor(config: config)
        supervisor.onStateChange = { [weak self] state in
            Task { @MainActor in
                if state == .failed {
                    self?.status = .failed("sidecar 连续崩溃，已停止重试")
                }
            }
        }
        supervisor.onDiagnostic = { [weak self] line in
            Task { @MainActor in
                self?.diagnostics.append("[stderr] \(line)")
            }
        }
        supervisor.onCrash = { [weak self] count, _ in
            Task { @MainActor in
                self?.diagnostics.append("[supervisor] sidecar 第 \(count) 次崩溃，退避重启")
            }
        }
        self.supervisor = supervisor
        status = .starting

        do {
            let startedClient = try await supervisor.start(serverHandler: broker)
            self.client = startedClient
            try await handshake(startedClient)
        } catch {
            status = .failed("\(error)")
        }
    }

    // MARK: - 演示模式

    func startDemo() async {
        guard !isBusy else { return }
        if let conversation {
            await broker.setAnswerer(conversation.makeAnswerer())
        }

        let transport = LoopbackTransport()
        _ = DemoPeer(transport: transport)
        let demoClient = DshAcpClient(transport: transport)
        client = demoClient

        do {
            try await demoClient.start(serverHandler: broker)
            try await handshake(demoClient)
        } catch {
            status = .failed("演示对端启动失败：\(error)")
        }
    }

    func stop() async {
        notificationTask?.cancel()
        notificationTask = nil
        if let supervisor {
            await supervisor.gracefulShutdown()
            self.supervisor = nil
        } else {
            await client?.gracefulShutdown()
        }
        client = nil
        sessionID = nil
        serverInfo = "未连接"
        status = .stopped
    }

    // MARK: - 握手与通知订阅

    private func handshake(_ client: DshAcpClient) async throws {
        let result = try await client.initialize(
            clientName: "CogniTerm",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        let sid = try await client.newSession(cwd: workspaceRoot)

        await MainActor.run {
            self.serverInfo = "\(result.serverInfo.name) \(result.serverInfo.version) · ACP v\(result.protocolVersion)"
            self.sessionID = sid
            self.status = .ready
        }
        observeNotifications(client)
    }

    private func observeNotifications(_ client: DshAcpClient) {
        notificationTask?.cancel()
        notificationTask = Task { [weak self, weak client] in
            guard let client else { return }
            for await note in await client.connection.notifications {
                await self?.conversation?.handleNotification(method: note.method, data: note.params)
            }
        }
    }

    private var isBusy: Bool {
        if case .starting = status { return true }
        if case .ready = status { return true }
        return false
    }
}
