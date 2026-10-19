import Foundation
import Combine
import AcpClient
import Persistence

/// Sidecar 生命周期与 ACP 连接的 App 层服务。
/// 真实模式：sandbox-exec(sidecar.sb) + node + dsh lib/bin.js --profile acp（--patch 关日志）。
/// 演示模式：LoopbackTransport + DemoPeer，无 runtime/API Key 也能走完整 UI/协议链路。
@MainActor
final class SidecarService: ObservableObject {
    /// 设置场景与主窗口共享同一实例（Settings 是独立 Scene）。
    static let shared = SidecarService()

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

    /// 需要重连才生效的设置快照（对应 SwiftData AppSettings 行）。
    struct Settings: Equatable {
        var policyMode: PolicyMode = .strict
        var sandboxMode: SandboxMode = .workspaceWrite
        var telemetryEnabled: Bool = false
        /// 新会话的启动缺省模型（provider 路由 + 模型 id）。
        ///
        /// 旧版这里只有 `AgentModel`——等于把 provider 硬编码成 deepseek-official，
        /// 挂上自定义端点之后就无法让会话默认跑在本地模型上，也无法在没有
        /// DeepSeek Key 的机器上使用。
        var defaultModel: DefaultModelSelection = .deepSeekDefault
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var serverInfo: String = "未连接"
    @Published private(set) var sessionID: String?
    /// 当前会话的配置项（dsh 0.2 广告模型 / 推理强度）。
    ///
    /// 状态由三个来源整体替换，从不做增量合并：
    ///   session/new 的响应 → resume 的响应 → `config_option_update` 通知
    /// 也从不本地"猜"：切换成功与否以服务端返回的整份状态为准。
    @Published private(set) var configOptions: [SessionConfigOption] = []
    /// 首次使用且 Keychain 无 Key 时置真，驱动 Onboarding 弹窗。
    @Published var needsOnboarding: Bool = false
    @Published var diagnostics: [String] = []
    /// 当前生效设置（start 时读）；改动后需重连才作用于 sidecar。
    @Published private(set) var settings: Settings = Settings()

    /// 在 start 前由界面注入。
    weak var conversation: ConversationModel?

    let broker = PermissionBroker()

    private(set) var client: DshAcpClient?
    private var supervisor: SidecarSupervisor?
    private var notificationTask: Task<Void, Never>?
    /// 演示对端必须被强引用：LoopbackTransport.responder 只 weak 捕获 DemoPeer，
    /// 临时对象会在 `_ =` 处立即释放，之后所有请求静默无应答（writeLine 直接 return）。
    private var demoPeer: DemoPeer?
    private let keychain = KeychainService()

    /// 注册给每个会话的终端 MCP server 条目（session/new 与 session/resume 都挂）。
    ///
    /// 真模式：SidecarService.start() 里先启动 TerminalMCPServer 再握手——
    /// dsh 的 `failOnStartupError: true` 会在会话创建时连不上 server 就整体失败，
    /// 所以启动失败时这里必须是 nil（agent 退化为没有 run_in_terminal 工具），
    /// 绝不能拿一个死端点去注册。
    /// 演示模式：恒 nil（DemoPeer 不挂 MCP）。
    private var terminalMCPServers: [McpServerConfig]?

    /// 当前工作区根目录（sidecar 的 WORKSPACE_ROOT / 会话 cwd 都取它）。
    ///
    /// 2026-10-17 改：默认值从「整个 $HOME」改为 `~/CogniTerm`。原默认值的实证
    /// 故障：5 个会话里用户问「当前目录有什么文件夹」全部失败——dsh 的 glob 用
    /// `--no-ignore --hidden`（dsh-tool-fs-search/lib/index.js:589）**全量遍历**
    /// 工作区，扫整个 home 既撞 macOS TCC（`~/Library/Containers/*` 直接
    /// `Operation not permitted (os error 1)`）又必然 30s 超时，4 次以用户手动
    /// 中止会话收场。默认一个「够小、归 App 管、用户可见」的目录，agent 的
    /// 默认视野才可用；要看别处由用户显式选（NSOpenPanel 自带 TCC 授权链）。
    ///
    /// 不能写成 `= Self.defaultWorkspaceURL()`：存储属性初始化器里不能引用
    /// 协变的 Self（编译错 covariant 'Self'）。逻辑放 WorkspacePaths，这里转发。
    var workspaceRoot: URL = WorkspacePaths.defaultWorkspaceURL()

    /// 默认工作区（转发 WorkspacePaths，测试与 MainSplitView 共用）。
    nonisolated static func defaultWorkspaceURL() -> URL {
        WorkspacePaths.defaultWorkspaceURL()
    }

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

    /// 能否拉起 sidecar —— 看的是**默认 provider 有没有可用凭据**。
    ///
    /// 旧版只认 DeepSeek Key，于是「全部跑本地模型」的部署被卡在 onboarding：
    /// 明明配好了本地端点，App 仍一直提示「需要 API Key」，怎么点都起不来。
    /// 现在按默认模型落在哪个 provider 分流：
    /// - 内置 DeepSeek → 必须有 Key；
    /// - 自定义端点 → 该端点要在清单里且可用（凭据缺失时 pi-ai 用占位值，不算阻碍）。
    ///
    /// 仍然 fail-closed：默认 provider 找不到对应端点就拒绝启动，而不是默默
    /// 回落到 DeepSeek 让用户以为在用本地模型。
    var canStart: Bool {
        let provider = settings.defaultModel.providerID
        if provider == DefaultModelSelection.deepSeekProvider { return hasAPIKey }
        return ModelEndpointStore.load().usableEndpoints.contains {
            ModelEndpoint.normalizedRouteID($0.id) == provider
        }
    }

    private var nodeURL: URL {
        runtimeDirectory.appendingPathComponent("node-darwin-arm64/bin/node")
    }

    /// dsh CLI 入口。
    private var cliURL: URL {
        runtimeDirectory.appendingPathComponent("node_modules/@deepseek-ai/dsh/lib/bin.js")
    }

    /// 收编 dsh 为 agentic core 的覆盖层（App/Resources/patches/cogniterm-core.patch.yml）。
    ///
    /// dsh 的 profile 是「声明式插件树」：$DSH_HOME/profiles/<name> 里 bundles 逐层合成，
    /// 再叠 profile 自己的 cordis.patch.yml，最后叠命令行 --patch。我们把收编策略放在
    /// 这一层而不是改 $DSH_HOME——用户改不动默认策略，且 dsh 升级时基线自动跟随。
    ///
    /// 实证：macOS 上 `--profile acp --patch <本文件> --dump-config` 合成成功，
    /// 插件启用数 84 → 72（关掉 web / subagent / workflow / session-log 上报），
    /// agent-loop、tools、sandbox、approval、permission、skill 等核心能力零误伤。
    private var corePatchURL: URL? {
        Self.patchURL(named: Self.corePatchFileName)
    }

    /// 隐私补丁（关闭随模型请求上报的会话日志）。与 corePatch 的 session-log
    /// 禁用重复，属双保险：corePatch 因故缺失时这一层仍兜底。
    private var noTelemetryPatchURL: URL? {
        Self.patchURL(named: "no-telemetry.yml")
    }

    /// 用户自定义模型端点的覆盖层文件名。
    ///
    /// 由 App 在每次 `start()` 前依据 `model-endpoints.json` 重新生成，落在
    /// Application Support（外层沙箱对 `HOME_DIR` 放行只读、对 `APP_SUPPORT_COGNITERM`
    /// 额外放行写，所以 dsh 读得到）。
    ///
    /// 为什么生成文件而不是塞进包内 patch：端点是用户配置，包内资源只读且随版本走。
    /// 为什么不是环境变量 + `!!js`：`providers` 是嵌套字典 + 模型数组，拼 JS 表达式
    /// 既不好读也不好排错；生成的文件还能用 `--dump-config` 直接核对合成结果。
    nonisolated static let providerPatchFileName = "user-providers.patch.yml"

    private var providerPatchURL: URL {
        applicationSupportDirectory
            .appendingPathComponent("CogniTerm", isDirectory: true)
            .appendingPathComponent(Self.providerPatchFileName)
    }

    /// 把渲染好的覆盖层写盘。失败只记诊断、不阻断启动——自定义模型是增强，
    /// 不该让 App 起不来（与「core patch 缺失必须 fail-closed」是两件事）。
    private func writeProviderPatch(_ yaml: String) throws {
        let url = providerPatchURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try yaml.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 收编覆盖层的资源文件名。**必须写全名**，含 `.patch` 段。
    ///
    /// `nonisolated`：`SidecarService` 整体是 `@MainActor`，但这个常量与下面的
    /// 纯函数都不碰实例状态，测试要在非 MainActor 上下文里直接断言。
    nonisolated static let corePatchFileName = "cogniterm-core.patch.yml"

    /// 在给定 Resources 目录里按**完整文件名**解析资源。
    ///
    /// ⚠️ 不要用 `Bundle.url(forResource:withExtension:)`：它把**最后一个 `.` 之后**
    ///    当成扩展名。文件名是 `cogniterm-core.patch.yml` 时，它会去找
    ///    `cogniterm-core.patch` + 扩展名 `yml` → **永远 nil**；而同目录的
    ///    `no-telemetry.yml` 正常命中。2026-10-16 的真实事故就是这么来的：
    ///    App 一直以「未找到 core patch」的降级路径启动，收编策略（身份提示词、
    ///    审批/沙箱语义对齐、能力裁剪、模型绑定）**全部静默失效**——而 bundle 里
    ///    文件确实存在，任何"文件在不在"的构建期检查都查不出来。
    ///    实测：`Bundle.url(forResource:"cogniterm-core", withExtension:"yml")` → nil。
    ///
    /// 抽成 `(name, resources)` 纯函数是为了可测：测试可从 app bundle 反推
    /// Resources 目录直接断言，不必依赖运行时 `Bundle.main`。
    nonisolated static func patchURL(named fileName: String, in resources: URL) -> URL? {
        let url = resources.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 打包后的 yml 落在 Contents/Resources 根（patches 是普通 group，非 folder
    /// reference，Xcode 会把子目录内容平铺）。
    nonisolated private static func patchURL(named fileName: String) -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return patchURL(named: fileName, in: resources)
    }

    // MARK: - 零配置启动

    /// App 首启入口：dsh 首启自行初始化 profile；凭据齐备直连，否则弹一次 Onboarding。
    func bootstrap() async {
        let fm = FileManager.default
        try? fm.createDirectory(at: dshHomeDirectory, withIntermediateDirectories: true)
        if canStart {
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

    /// 设置变更（审批模式 / sidecar 沙箱 / 遥测 / 默认模型）。立即生效的部分同步到 UI，
    /// 作用于 sidecar 的部分（沙箱、遥测、模型）在下次 start 时注入。
    func update(settings: Settings) {
        self.settings = settings
        conversation?.policyMode = settings.policyMode
    }

    /// 沙箱模式 → 外层 seatbelt profile 文件名。
    ///
    /// 两档墙对应两档信任（2026-10-17 定，根因见 sidecar-writable.sb 头注）：
    ///   - read-only：confined 档（`sidecar.sb`）——写仅限 WORKSPACE_ROOT 单根，
    ///     HOME 只读。内核级「基本不动」。
    ///   - workspace-write / 关闭沙箱：writable 档（`sidecar-writable.sb`）——
    ///     HOME 全量写 + 凭据墙 deny。dsh 内层才是细粒度策略的位置
    ///     （默认单根 + escalation 逐次审批），外层只兜底。
    ///
    /// 为什么 workspace-write 不能继续用 confined 档：dsh 内层支持逐次
    /// escalation（写工作区外路径 → 审批卡允许 → 本次放宽），而 confined 档的
    /// WORKSPACE_ROOT 是启动时静态注入的单根，跟不动内层决策——用户点了「允许」
    /// 照样被 sandbox-exec EPERM（审批赢了，内核墙没赢）。
    ///
    /// `nonisolated` 纯函数：测试要直接断言映射，不启动 sidecar。
    nonisolated static func sandboxProfileName(for mode: SandboxMode) -> String {
        switch mode {
        case .readOnly: return "sidecar.sb"
        case .workspaceWrite, .off: return "sidecar-writable.sb"
        }
    }

    /// 按当前沙箱模式取外层 profile；缺失即 fail-closed（绝不裸连）。
    ///
    /// 选哪个档位写进诊断——切换沙箱模式要重连才生效，用户需要能从诊断里
    /// 确认这次启动实际用的哪面墙。
    private func requireSandboxProfile() throws -> URL {
        let name = Self.sandboxProfileName(for: settings.sandboxMode)
        if let url = Self.patchURL(named: name,
                                   in: Bundle.main.resourceURL ?? Bundle.main.bundleURL) {
            diagnostics.append("[launcher] 外层沙箱 profile：\(name)（沙箱模式 \(settings.sandboxMode.rawValue)）")
            return url
        }
        struct ProfileMissing: Error {}
        throw ProfileMissing()
    }

    /// 收编覆盖层必须存在；缺失即视为部署不完整（fail-closed）。
    /// 与 requireSandboxProfile 同理：这两样都不是"可选项"，而是 App 行为的定义。
    private func requireCorePatch() throws -> URL {
        if let url = corePatchURL { return url }
        let expected = Bundle.main.resourceURL?
            .appendingPathComponent(Self.corePatchFileName).path ?? Self.corePatchFileName
        diagnostics.append("[launcher] 期望补丁：\(expected)")
        diagnostics.append("[launcher] 实际 Resources：\(Bundle.main.resourceURL?.path ?? "nil")")
        struct CorePatchMissing: Error {}
        throw CorePatchMissing()
    }

    // MARK: - 真实 runtime

    func start() async {
        guard !isBusy else { return }

        guard canStart else {
            status = .needsKey
            needsOnboarding = true
            diagnostics.append(
                "[launcher] 拒绝启动：默认模型 provider=\(settings.defaultModel.providerID) "
                + "缺少可用凭据（内置 DeepSeek 需要 Key；自定义端点需要在「模型端点」里可用）"
            )
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
            // fs/read_text_file：workspace 边界 + 1MB 上限（fail-closed）。
            let root = workspaceRoot.standardizedFileURL.path
            await broker.setFileSystemReader { path, line, limit in
                try WorkspaceFileReader(workspaceRoot: root).read(path: path, line: line, limit: limit)
            }
        }

        // 终端 MCP server：agent 的 run_in_terminal 工具经它注入我们的 PTY。
        // 必须**先于**下面的握手（session/new）启动——dsh 对客户端提供的
        // mcpServers 用 failOnStartupError: true，会话创建时连不上就整体失败。
        // 启动失败不阻断 sidecar：agent 退化为没有终端工具（诊断里记一笔）。
        do {
            try await TerminalMCPServer.shared.start()
            terminalMCPServers = TerminalMCPServer.shared.serverConfig.map { [$0] }
            diagnostics.append("[launcher] 终端 MCP server：\(TerminalMCPServer.shared.endpointDescription)")
        } catch {
            terminalMCPServers = nil
            diagnostics.append("[launcher] 终端 MCP server 启动失败，agent 将没有 run_in_terminal 工具：\(error)")
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
            // App bundle 根。必须注入：dsh 的 `--patch` 文件在 Contents/Resources
            // **根**，不在 RUNTIME_DIR（…/Resources/runtime）之下。开发期 app 在
            // $HOME 内，被 HOME 读放行顺带覆盖所以无感；装到 /Applications 后
            // 没这条 sb 就放行不到它，sidecar 启动即崩（2026-10-16 实测）。
            "-D", "APP_BUNDLE=\(Bundle.main.bundleURL.path)",
            nodeURL.path, cliURL.path, "--profile", "acp",
        ]
        // agentic core 覆盖层：缺失即 fail-closed，绝不静默降级。
        // 它承载的不是「偏好」而是**语义**——身份与系统提示词、审批策略/沙箱模式
        // 的对齐、能力裁剪（web / subagent / workflow / 自带 bash）。
        // 丢了它 App 会以 raw dsh 的默认策略启动，与我们收编的设计不一致；
        // 而"能跑"会让人误以为一切正常（2026-10-16 的真实事故）。
        let corePatch: URL
        do {
            corePatch = try requireCorePatch()
        } catch {
            status = .failed("缺少内置的 cogniterm-core.patch.yml，已拒绝以未收编的 dsh 默认 profile 启动")
            return
        }
        // 顺序有意义：--patch 按出现顺序叠加，后者覆盖前者。
        arguments += ["--patch", corePatch.path]
        // 遥测两层开关：session-log-deepseek 补丁（随模型请求上报会话日志）
        // + DSH_TELEMETRY_DISABLED 环境变量（OTel 整体退出）。默认全关；
        // 用户在设置里显式开启时才两个都放行。
        if settings.telemetryEnabled {
            diagnostics.append("[launcher] 遥测已按用户设置启用（OTel + 会话日志上报）")
        } else {
            if let patch = noTelemetryPatchURL {
                arguments += ["--patch", patch.path]
            } else {
                diagnostics.append("[launcher] 警告：未找到包内 no-telemetry.yml，仅靠 DSH_TELEMETRY_DISABLED 兜底")
            }
        }

        // 自定义模型端点（本地 Qwen / 内网网关 / 任意 OpenAI 兼容端点）。
        //
        // dsh-base 把 `llm-pi-ai` 挂成休眠态（零路由），这里给出的 providers 会让
        // 路由注册出来；因为 dsh-acp 的 model 选项是**按 provider 分组列出全部模型**，
        // 所以挂上之后会话内的模型选择器会直接多出「本地 Qwen3.8-27B」这样的分组，
        // 不需要再去点重启。要改端点本身才需要重连。
        let customEndpoints = ModelEndpointStore.load().usableEndpoints
        if let yaml = ProviderPatch.render(endpoints: customEndpoints) {
            do {
                try writeProviderPatch(yaml)
                arguments += ["--patch", providerPatchURL.path]
                let names = customEndpoints.map(\.displayName).joined(separator: "、")
                diagnostics.append("[launcher] 已挂载 \(customEndpoints.count) 个自定义模型端点：\(names)")
            } catch {
                diagnostics.append("[launcher] 自定义模型端点覆盖层写入失败，本次仅用内置模型：\(error)")
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(runtimeDirectory.path)/node-darwin-arm64/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["DEEPSEEK_API_KEY"] = keychain.read() ?? ""
        // dsh 内层沙箱模式（dsh-sandbox-policy 读 DSH_PERMISSION_MODE：
        // read-only / workspace-write / danger-full-access）。
        environment["DSH_PERMISSION_MODE"] = settings.sandboxMode.dshPermissionMode
        // 模型：core patch 里 **两处** 都读这个变量——
        //   agent-default-model（别的入口的缺省值）
        //   acp（真正决定 CogniTerm 会话模型的落点；dsh-acp README:
        //        "Every session the server creates uses the provider and
        //         model configured here"）
        // 只绑 agent-default-model 是无效的：dsh-acp 不消费 agentDefaultModel。
        // 名字带 COGNITERM 前缀而非裸 DSH_MODEL，避免与用户自己 shell 里的
        // 同名变量互相干扰（我们只改子进程环境，但诊断日志会打印环境）。
        environment["DSH_COGNITERM_MODEL"] = settings.defaultModel.modelID
        // provider 同样走环境变量：core patch 的 `acp` 与 `agent-default-model`
        // 两处都读它。指向自定义端点时这里是该端点的路由名。
        environment["DSH_COGNITERM_PROVIDER"] = settings.defaultModel.providerID
        // 自定义端点的凭据：pi-ai 的 `apiKeyEnv` 是一个 credential ref，按请求解析，
        // 所以只要把同名变量注入子进程环境即可，不需要把 key 写进 patch。
        //
        // **这个变量必须始终有值**（实证 2026-10-19，headless 真跑）：
        // pi-ai 对 `openai-completions` 路由无条件要求凭据——变量缺失时请求直接失败
        // `PI_AI_ERROR: No API key for provider: <route>`，即使上游是根本不校验
        // Authorization 的本地 vLLM。所以界面留空的端点注入占位值（上游会忽略这个头），
        // 而不是跳过不注入。
        for endpoint in customEndpoints {
            let stored = endpoint.apiKeyAccount.flatMap { KeychainService(account: $0).read() }
            let key = (stored?.isEmpty == false) ? stored! : ModelEndpoint.placeholderAPIKey
            environment[endpoint.apiKeyEnvName] = key
        }
        stripProxyEnvironment(&environment)
        if settings.telemetryEnabled {
            environment.removeValue(forKey: "DSH_TELEMETRY_DISABLED")
        } else {
            environment["DSH_TELEMETRY_DISABLED"] = "1"
        }
        environment["NODE_NO_WARNINGS"] = "1"
        // dsh 用户态目录：profiles 补丁/会话记录全部落在 Application Support，随包只读。
        environment["DSH_HOME"] = dshHomeDirectory.path

        let config = SidecarConfig(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: workspaceRoot,
            // tool_call 关联缓存与 ConversationModel 共享同一实例：
            // 连接层在分帧路径同步记录，审批请求到达时命令文本必已入库。
            toolCallTracker: conversation?.toolCalls
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
        // 演示对端不挂 MCP：终端工具依赖真实 sidecar + PTY，演示模式没有。
        terminalMCPServers = nil
        if let conversation {
            await broker.setAnswerer(conversation.makeAnswerer())
        }

        let transport = LoopbackTransport()
        demoPeer = DemoPeer(transport: transport)
        let demoClient = DshAcpClient(transport: transport, toolCallTracker: conversation?.toolCalls)
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
        demoPeer = nil
        sessionID = nil
        // 终端 MCP server **不随 stop 关闭**：它服务的是"App 生命周期内的所有
        // 会话"而不是单个 sidecar 连接。重新连接时 start() 幂等复用同一监听
        // （端点不变，session/new 重新注册即可）。进程退出时监听自然消亡。
        terminalMCPServers = nil
        // 选项集是**会话态**，跟着会话一起消失：留着会让人以为切了还在。
        configOptions = []
        serverInfo = "未连接"
        status = .stopped
    }

    // MARK: - 会话配置项（configOptions）

    /// 按 id 取配置项（如 `SessionConfigID.model`）。
    func configOption(id: String) -> SessionConfigOption? {
        configOptions.first { $0.id == id }
    }

    /// 模型选择项：先按 category 找（UX 语义，ACP 推荐），再回落 id。
    var modelConfigOption: SessionConfigOption? {
        configOptions.first { $0.category == "model" } ?? configOption(id: SessionConfigID.model)
    }

    /// 实时切换一个配置项（`session/set_config_option`）。
    ///
    /// 改的是**当前会话后续轮次**的取值，不改启动参数、不触发重连——
    /// 与设置页的「默认模型」（`DSH_COGNITERM_MODEL`，下次 start 生效）是两件事。
    /// 成功后用服务端返回的整份状态替换本地状态；失败只记诊断，不乐观更新。
    func setConfigOption(id: String, value: String) async {
        guard let client, let sessionID else {
            conversation?.appendSystem("尚未建立会话，无法切换 \(id)")
            return
        }
        let option = configOption(id: id)
        do {
            let options = try await client.setConfigOption(sessionId: sessionID, configId: id, value: value)
            configOptions = options
            let applied = options.first { $0.id == id }
            conversation?.appendSystem(
                "会话\(option?.label ?? id)已切换为 \(applied?.currentLabel ?? value)（对后续轮次生效）")
        } catch {
            diagnostics.append("[set_config_option] id=\(id) value=\(value) → \(error)")
            conversation?.appendSystem("切换 \(option?.label ?? id) 失败：\(error)")
        }
    }

    // MARK: - 会话控制

    /// 在同一 sidecar 连接上开**新会话**（不重连、不断传输）。
    ///
    /// 与 applyWorkspace() 的 stop+start 的区别：那个是「换工作区必须重建 sidecar」
    /// （sb 的 WORKSPACE_ROOT 与 dsh 内层 sandbox workspaceRoot 都是启动时定死的），
    /// 这个只是同一连接上新开 session——用户想「忘掉当前上下文重新聊」时用。
    /// 旧 UI 根本没有新会话入口，想重新开始只能断开再连接（顺带重读 Keychain、
    /// 重握手、重播种 profile），既慢又容易让人以为出了故障。
    func newSession() async {
        guard let client else {
            conversation?.appendSystem("尚未连接 sidecar，无法创建会话")
            return
        }
        do {
            let session = try await client.newSession(cwd: workspaceRoot, mcpServers: terminalMCPServers)
            guard let sid = session.sessionId else {
                throw AcpError.decode("session/new missing sessionId")
            }
            self.sessionID = sid
            applyConfigOptions(session.configOptions, reason: "session/new")
            conversation?.beginSession()
            conversation?.appendSystem("已开始新会话（工作区 \(workspaceRoot.path)）")
        } catch {
            diagnostics.append("[newSession] \(error)")
            conversation?.appendSystem("创建会话失败：\(error)")
        }
    }

    /// 中断当前 prompt 轮次（session/cancel）；dsh 会以 stopReason=cancelled 收尾。
    func cancelCurrent() async {
        guard let sessionID, let client else { return }
        do {
            try await client.cancel(sessionId: sessionID)
            conversation?.setWorking(false)
        } catch {
            diagnostics.append("[cancel] \(error)")
        }
    }

    /// 列出 dsh 持久化会话（跨重启有效；cwd 按当前工作区过滤）。
    func listHistory() async throws -> [SessionInfo] {
        guard let client else { return [] }
        return try await client.listSessions(cwd: workspaceRoot).sessions
    }

    /// 恢复一个历史会话：resume 后切换当前 sessionID 并重置展示面。
    func resumeSession(_ info: SessionInfo) async {
        guard let client else { return }
        do {
            let result = try await client.resume(sessionId: info.sessionId, cwd: workspaceRoot, mcpServers: terminalMCPServers)
            sessionID = info.sessionId
            applyConfigOptions(result.configOptions, reason: "session/resume")
            conversation?.beginSession()
            conversation?.appendSystem("已恢复会话 \(info.sessionId)（resume 不回放历史消息）")
        } catch {
            diagnostics.append("[resume] \(error)")
            conversation?.appendSystem("恢复会话失败：\(error)")
        }
    }

    // MARK: - 握手与通知订阅

    private func handshake(_ client: DshAcpClient) async throws {
        let result = try await client.initialize(
            clientName: "CogniTerm",
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        )
        let session = try await client.newSession(cwd: workspaceRoot, mcpServers: terminalMCPServers)
        let sid = try {
            guard let id = session.sessionId else { throw AcpError.decode("session/new missing sessionId") }
            return id
        }()

        await MainActor.run {
            self.serverInfo = "\(result.serverInfo.name) \(result.serverInfo.version) · ACP v\(result.protocolVersion)"
            self.sessionID = sid
            self.status = .ready
        }
        applyConfigOptions(session.configOptions, reason: "session/new")
        conversation?.beginSession()
        observeNotifications(client)
    }

    /// 用一份服务端给的完整选项集替换本地状态。
    ///
    /// `nil` 与 `[]` 不是一回事，必须分开处理：**nil** 表示这个响应里根本没有
    /// `configOptions`（对端未实现该扩展），**空数组**才是"实现了但没有可选项"。
    /// 把 nil 一律当空数组，会让"对端不支持"和"对端支持但列表为空"两种完全不同的
    /// 情况在 UI 上长得一模一样——都是空白，没人能从界面看出区别。
    /// 两者都记进诊断（不静默）。
    ///
    /// 非 private 是为了可测：nil 分支只能靠构造"对端不回该字段"的响应触发，
    /// 而这条分支的语义（清空 vs 判别为不支持）正是最容易写错的地方。
    func applyConfigOptions(_ options: [SessionConfigOption]?, reason: String) {
        guard let options else {
            configOptions = []
            diagnostics.append("[config] \(reason) 未返回 configOptions（对端可能未实现会话配置项）")
            return
        }
        configOptions = options
        if options.isEmpty {
            diagnostics.append("[config] \(reason) 返回了空的 configOptions（对端支持但当前无选项）")
        }
    }

    private func observeNotifications(_ client: DshAcpClient) {
        notificationTask?.cancel()
        notificationTask = Task { [weak self, weak client] in
            guard let client else { return }
            // self 与 conversation 同为 @MainActor，同执行体不需要 await；
            // connection 是非隔离 actor，取其 AsyncStream 需要 await。
            for await note in await client.connection.notifications {
                self?.consume(note)
            }
        }
    }

    /// 通知单一入口：会话配置项在这里收（SidecarService 是 configOptions 的唯一持有者），
    /// 其余事件转发给展示面。**不做两份状态**——重复持有必然出现两边不一致。
    ///
    /// 非 private 是为了可测：这段路由的可观测行为（哪些通知改状态、哪些丢弃）只能
    /// 端到端断言，靠"读代码觉得对"是不够的。
    func consume(_ note: AcpConnection.Notification) {
        if note.method == AcpMethod.sessionUpdate,
           let data = note.params,
           let params = try? JSONDecoder.acp.decode(SessionNotificationParams.self, from: data),
           let update = params.update,
           update.sessionUpdate == SessionUpdateEvent.Kind.configOptionUpdate {
            // 服务端主动广播（dsh 在拓扑变化后发）。sessionId 对不上就丢弃：
            // 切换到工作区/恢复会话时老会话的迟到通知不能覆盖当前会话的选项集。
            if params.sessionId != nil && params.sessionId != sessionID {
                diagnostics.append("[config] 丢弃非当前会话的 config_option_update（\(params.sessionId ?? "")）")
            } else if let options = update.sessionConfigOptions {
                applyConfigOptions(options, reason: "config_option_update")
            } else {
                // 广播解析不出来 = 这一条坏了，不是"状态被重置"。保留上一份可用状态，
                // 清空反而会让用户失去选择器却看不到任何原因。
                diagnostics.append("[config] config_option_update 载荷无法解析，保留上一份选项集")
            }
        }
        conversation?.handleNotification(method: note.method, data: note.params)
    }

    private var isBusy: Bool {
        if case .starting = status { return true }
        if case .ready = status { return true }
        return false
    }
}

/// App 沙箱设置 → dsh 内层沙箱模式（dsh-sandbox-policy 的 DSH_PERMISSION_MODE）。
extension SandboxMode {
    var dshPermissionMode: String {
        switch self {
        case .readOnly: return "read-only"
        case .workspaceWrite: return "workspace-write"
        case .off: return "danger-full-access"
        }
    }
}

/// 默认工作区路径（独立命名空间：SidecarService 的存储属性初始化器不能用
/// 协变 Self，MainSplitView / 测试也要共用同一份逻辑）。
enum WorkspacePaths {
    /// `~/CogniTerm`（不存在则创建）。
    ///
    /// 之所以是用户主目录下的**可见**目录而不是 Application Support 里的隐藏
    /// 目录：这是个终端产品，用户会在 Finder 里找「我的工作区」，藏起来等于没有。
    static func defaultWorkspaceURL() -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("CogniTerm", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }
}

/// sidecar 子进程环境必须剔掉的代理类变量。
///
/// 为什么这是硬要求而不是洁癖：sidecar 走 `ProcessInfo.processInfo.environment`
/// 全量继承，而启动 App 的进程常常带着**临时的 loopback 代理**（本机开发环境就是如此：
/// 每次工具调用注入 `HTTP(S)_PROXY=http://127.0.0.1:<临时端口>`，端口归该次调用所有、
/// 调用一结束就消失）。dsh 会把这些变量当"请求走哪条路"的依据，于是：
///   死端口 → `connect ECONNREFUSED`（约 10ms，请求根本没出机器）
///   → dsh-llm 归类为 TRANSPORT → 退避重试 5 次全挂 → turn/end error
///   → ACP 把 prompt 判失败返回 -32603。
///
/// 实测对照（同一探针、同一 runtime，唯一变量是这几个变量）：
///   带死代理：`Internal error: turn failed: DeepSeek Messages transport failed`
///   不带代理：正常拿到 DeepSeek 的 HTTP 应答。
///
/// 另外 sidecar.sb 的设计契约就是"直连 api.deepseek.com"（只放行 `*:443` 出站），
/// 代理既非设计意图也非用户偏好。若将来真要支持代理，应做成显式设置项，
/// 而不是靠继承环境悄悄生效。
private let proxyEnvironmentNames = [
    "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    "http_proxy", "https_proxy", "all_proxy", "no_proxy",
    "NODE_USE_ENV_PROXY",
]

extension SidecarService {
    /// 从待注入 sidecar 的环境里剔除代理类变量，并记录被剔除的内容（不静默）。
    func stripProxyEnvironment(_ environment: inout [String: String]) {
        for name in proxyEnvironmentNames {
            if let value = environment.removeValue(forKey: name) {
                diagnostics.append("[launcher] 已剔除继承的代理变量 \(name)=\(value)（sidecar 按设计直连模型端点）")
            }
        }
    }
}
