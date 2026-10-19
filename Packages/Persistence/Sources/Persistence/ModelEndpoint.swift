import Foundation

// MARK: - 用户自建的模型端点

/// 一个用户自建的 OpenAI 兼容端点（本地 vLLM / SGLang / 内网网关 / 任意代理）。
///
/// 为什么单独一个文件而不是塞进 `AppSettings`：
/// 端点是一份**可增删的配置清单**，不是单行的应用设置；而且每次改动都要重新生成
/// dsh 的 patch 覆盖层，天然属于「启动期配置」而非「运行时状态」。
///
/// 接线方式（已实证，不需要 fork dsh、也不需要新增插件）：
///   `dsh-base` 默认 profile 已经把 `@deepseek-ai/dsh-llm-pi-ai` 挂成**休眠态**
///   （零路由），只要给它的 config 填 `providers`，路由就会注册出来；
///   而 `dsh-acp` 的 Config 里 `provider` / `model` 都是自由字符串
///   （`provider: Schema.string()`），所以会话可以按 route 名直接选中它。
public struct ModelEndpoint: Codable, Equatable, Identifiable, Sendable {
    /// 路由名，也是 pi-ai 的 provider key（小写连字符，见 `normalizedRouteID`）。
    public var id: String
    public var displayName: String
    /// 例如 `http://localhost:8000/v1`，末尾斜杠会被规整掉。
    public var baseURL: String
    public var models: [ModelSpec]
    /// 本地推理经常几十秒才出第一个 token，pi-ai 默认超时偏短。
    public var timeoutMs: Int?
    /// Keychain account；nil 表示该端点无鉴权（本地 vLLM 常见），不注入 `apiKeyEnv`。
    public var apiKeyAccount: String?
    public var enabled: Bool

    public init(id: String,
                displayName: String,
                baseURL: String,
                models: [ModelSpec] = [],
                timeoutMs: Int? = nil,
                apiKeyAccount: String? = nil,
                enabled: Bool = true) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.models = models
        self.timeoutMs = timeoutMs
        self.apiKeyAccount = apiKeyAccount
        self.enabled = enabled
    }

    /// pi-ai 的凭据引用名。`apiKeyEnv` 走的是 harness 的 credential seam，
    /// 所以我们只需在拉起 sidecar 时把同名环境变量注入子进程。
    public var apiKeyEnvName: String {
        "COGNITERM_KEY_" + Self.normalizedRouteID(id).uppercased().replacingOccurrences(of: "-", with: "_")
    }

    /// 无鉴权端点也要用的占位凭据。
    ///
    /// 实证（2026-10-19，headless 真跑）：pi-ai 对 `openai-completions` 路由**强制**
    /// 要求有凭据——不写 `apiKeyEnv` 时请求直接失败
    /// `PI_AI_ERROR: No API key for provider: local-qwen`，即使上游是根本不校验
    /// Authorization 的本地 vLLM。所以 patch 里始终写 `apiKeyEnv`，而用户在界面上
    /// 留空时由 App 注入这个占位值（vLLM / SGLang 会忽略这个头）。
    public static let placeholderAPIKey = "local"

    /// 路由名规范化。
    ///
    /// pi-ai 的手声明路由要求「lowercase hyphenated identifier」，而且这个名字会
    /// 进 ACP 的模型选项 value（`provider/model` 形式），含空格或斜杠会让选择器
    /// 的 value 解析歧义。所以这里做强规范化而不是只做校验。
    public static func normalizedRouteID(_ raw: String) -> String {
        var out = ""
        for ch in raw.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
            } else if ch == "-" || ch == "_" || ch == " " || ch == "." {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "provider" : out
    }

    /// baseURL 规整：去尾部斜杠、去空白。空串视为不可用。
    public var normalizedBaseURL: String {
        var value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// 能在 patch 里落地的必要条件。缺失时该端点整条跳过（不让它把 sidecar 拖挂）。
    public var isUsable: Bool {
        enabled
            && !normalizedBaseURL.isEmpty
            && (normalizedBaseURL.hasPrefix("http://") || normalizedBaseURL.hasPrefix("https://"))
            && !models.filter({ !$0.id.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty
    }
}

/// 端点上声明的一个模型。
///
/// `contextWindow` 必须如实填：填大了服务端直接 400，填小了 dsh 会提前压缩上下文。
/// `maxTokens` 缺省时由 pi-ai 用端点的 `defaultMaxTokens` 兜底。
public struct ModelSpec: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String?
    public var contextWindow: Int?
    public var maxTokens: Int?

    public init(id: String, name: String? = nil, contextWindow: Int? = nil, maxTokens: Int? = nil) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
    }
}

// MARK: - 清单存储

/// 端点清单的磁盘形态。
///
/// 刻意**不用 SwiftData**：加表要走迁移，而「改一个模型端点的 baseURL」不该触发
/// 数据库 schema 变更；这份清单也不是业务数据（会话、审批规则才是）。
/// 文件读坏时按空清单回落（fail-soft）——模型配置是偏好，不是安全边界，
/// 坏掉的 JSON 不该让 App 无法启动，诊断里会留一行。
public struct ModelEndpointStore: Codable, Equatable, Sendable {
    public var endpoints: [ModelEndpoint]

    public init(endpoints: [ModelEndpoint] = []) {
        self.endpoints = endpoints
    }

    /// `~/Library/Application Support/CogniTerm/model-endpoints.json`
    public static func defaultFileURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CogniTerm", isDirectory: true)
            .appendingPathComponent("model-endpoints.json")
    }

    public static func load(from url: URL = defaultFileURL()) -> ModelEndpointStore {
        guard let data = try? Data(contentsOf: url) else { return ModelEndpointStore() }
        return (try? JSONDecoder().decode(ModelEndpointStore.self, from: data)) ?? ModelEndpointStore()
    }

    public func save(to url: URL = defaultFileURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// 能在 patch 里落地的端点（顺序保持用户在 UI 里的排列）。
    public var usableEndpoints: [ModelEndpoint] {
        endpoints.filter(\.isUsable)
    }

    public func endpoint(withID id: String) -> ModelEndpoint? {
        endpoints.first { $0.id == id }
    }
}

// MARK: - patch 渲染

/// 把端点清单渲染成 dsh 的 patch 覆盖层。
///
/// 为什么走 patch 而不是环境变量：
/// `providers` 是一个嵌套字典 + 模型数组，用 `!!js` 拼字符串既不可读也不好排错；
/// 而 patch 是 dsh 官方留给调用方的配置覆盖入口（`--patch` 按出现顺序叠加），
/// 生成的文件还能 `--dump-config` 直接核对。
///
/// 生成的每一行都有对应依据，改动前请先读 `dsh-llm-pi-ai/README.md` 的
/// Configure provider routes 一节。
public enum ProviderPatch {

    /// 渲染结果；清单里没有可用端点时返回 nil（调用方就不追加这条 `--patch`）。
    public static func render(endpoints: [ModelEndpoint]) -> String? {
        let usable = endpoints.filter(\.isUsable)
        guard !usable.isEmpty else { return nil }

        var lines: [String] = [
            "# 由 CogniTerm 依据「设置 → 模型端点」生成，请勿手工编辑。",
            "# 重新保存端点配置会覆盖本文件。生成时间：\(ISO8601DateFormatter().string(from: Date()))",
            "",
            "# pi-ai 在 dsh-base 里是休眠挂载的（零路由），给出 providers 即注册路由。",
            "- id: llm-pi-ai",
            "  config:",
            "    providers:",
        ]

        for endpoint in usable {
            let route = ModelEndpoint.normalizedRouteID(endpoint.id)
            lines.append("      \(route):")
            lines.append("        displayName: \(yaml(endpoint.displayName.isEmpty ? route : endpoint.displayName))")
            lines.append("        api: openai-completions")
            lines.append("        baseURL: \(yaml(endpoint.normalizedBaseURL))")
            // 无条件写：pi-ai 对无鉴权端点也要求非空凭据（见 placeholderAPIKey 的实证）。
            lines.append("        apiKeyEnv: \(endpoint.apiKeyEnvName)")
            if let timeout = endpoint.timeoutMs, timeout > 0 {
                lines.append("        timeoutMs: \(timeout)")
            }
            lines.append("        models:")
            for model in endpoint.models where !model.id.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("          - id: \(yaml(model.id))")
                if let name = model.name, !name.isEmpty {
                    lines.append("            name: \(yaml(name))")
                }
                if let window = model.contextWindow, window > 0 {
                    lines.append("            contextWindow: \(window)")
                }
                if let cap = model.maxTokens, cap > 0 {
                    lines.append("            maxTokens: \(cap)")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// YAML 标量：统一单引号包裹，内部单引号用 `''` 转义。
    /// 不用裸标量是因为模型 id 里常见 `:`（如 `qwen3.8:27b`）会被 YAML 当成 mapping。
    private static func yaml(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
