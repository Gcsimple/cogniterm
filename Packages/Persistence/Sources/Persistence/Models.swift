import Foundation
import SwiftData
import PolicyEngine

@available(macOS 14.0, *)
@Model
public final class Workspace {
    @Attribute(.unique) public var id: UUID
    /// 绝对路径，规范化（standardizedFileURL.path）后存储。
    @Attribute(.unique) public var path: String
    public var name: String
    public var createdAt: Date
    public var lastOpenedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \SessionRecord.workspace)
    public var sessions: [SessionRecord]

    public init(id: UUID = UUID(),
                path: String,
                name: String? = nil,
                createdAt: Date = Date(),
                lastOpenedAt: Date = Date(),
                sessions: [SessionRecord] = []) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.sessions = sessions
    }
}

@available(macOS 14.0, *)
@Model
public final class SessionRecord {
    @Attribute(.unique) public var id: UUID
    /// ACP initialize 后由 sidecar 分配的会话 ID；尚未 newSession 时为 nil。
    public var acpSessionID: String?
    /// JSONL 文件名主干（用于与日志目录对账）。
    public var jsonlStem: String
    public var stopReason: String?
    /// JSONL 轨迹文件绝对路径（可能在恢复时才补齐）。
    public var jsonlPath: String?
    public var title: String?
    public var createdAt: Date

    public var workspace: Workspace?

    public init(id: UUID = UUID(),
                acpSessionID: String? = nil,
                jsonlStem: String,
                stopReason: String? = nil,
                jsonlPath: String? = nil,
                title: String? = nil,
                createdAt: Date = Date(),
                workspace: Workspace? = nil) {
        self.id = id
        self.acpSessionID = acpSessionID
        self.jsonlStem = jsonlStem
        self.stopReason = stopReason
        self.jsonlPath = jsonlPath
        self.title = title
        self.createdAt = createdAt
        self.workspace = workspace
    }
}

@available(macOS 14.0, *)
@Model
public final class ApprovalRuleRecord {
    @Attribute(.unique) public var id: UUID
    public var tool: String
    public var pattern: String
    public var workspaceScoped: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(),
                tool: String,
                pattern: String,
                workspaceScoped: Bool = true,
                createdAt: Date = Date()) {
        self.id = id
        self.tool = tool
        self.pattern = pattern
        self.workspaceScoped = workspaceScoped
        self.createdAt = createdAt
    }

    public convenience init(_ rule: PolicyEngine.ApprovalRule) {
        self.init(id: rule.id,
                  tool: rule.tool,
                  pattern: rule.pattern,
                  workspaceScoped: rule.workspaceScoped,
                  createdAt: rule.createdAt)
    }

    public var asPolicyRule: PolicyEngine.ApprovalRule {
        PolicyEngine.ApprovalRule(id: id,
                                  tool: tool,
                                  pattern: pattern,
                                  workspaceScoped: workspaceScoped,
                                  createdAt: createdAt)
    }
}

/// 三模式：strict=每次询问；rules=命中允许规则才自动放行；closed=一律拒绝。
public enum PolicyMode: String, CaseIterable, Codable, Sendable {
    case strict
    case rules
    case closed
}

/// 外层 seatbelt 粗墙模式（对应 dsh-sandbox-policy）。
public enum SandboxMode: String, CaseIterable, Codable, Sendable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case off
}

/// 默认模型（经 `DSH_COGNITERM_MODEL` 注入，由 core patch 读进 dsh profile）。
///
/// ⚠️ 落点是 **`acp` 插件的 config**，不只是 `agent-default-model`：
///    dsh-acp 并不消费 agentDefaultModel（消费者只有 dsh-api-session-controller /
///    dsh-webhook / dsh-headless / dsh-tool-cordis），ACP 会话的模型由 `acp` 行的
///    provider/model 决定。只绑 agent-default-model 会让选择器变成空操作——
///    2026-10-16 踩过：27 个会话日志里 request/header 的 model 恒为 acp 行的值，
///    与设置页注入值不一致。
///
/// rawValue 即**上线的 wire model id**，拼错的代价不是本地报错：
/// `dsh-llm-deepseek` 的 `modelInfo()` 对目录外的 id 会原样透传
/// （`{ id: model, name: model, inputModalities: ["text"] }`），错 id 会一路发到
/// 服务端。所以这里的取值必须逐字来自 vendored runtime 的 `DEFAULT_MODELS`：
///   - `deepseek-flash`  （dsh 目录 id；账号侧展示名 DeepSeek-V4.1-Flash）
///   - `deepseek-v4-pro` （dsh 目录 id；展示名 DeepSeek-V4-Pro）
/// 实测账号模型目录：`GET /v1/models` → `["deepseek-flash", "deepseek-v4-pro"]`。
///
/// ⚠️ 曾经的取值 `deepseek-v4-flash` **不在目录里**，只是网关接受的别名
/// （请求它以该 id 发出，响应里的 `model` 回的是 `deepseek-flash`）。它能用，
/// 但会带来一个可见缺陷：`AcpModelControl.state()` 发现 currentValue 不在
/// catalog choices 里时会**合成**一条 `name == value` 的选项塞进分组，
/// 于是会话模型选择器里出现两条其实是同一个模型的条目
/// （`deepseek-v4-flash` 合成项 + `DeepSeek-V4.1-Flash` 目录项）。
/// 2026-10-16 用真实 dsh 实测确认了这个 3 条目的选择器，故改回规范 id。
public enum AgentModel: String, CaseIterable, Codable, Sendable {
    /// DeepSeek-V4.1-Flash：默认档。
    case flash = "deepseek-flash"
    /// DeepSeek-V4-Pro：更强的 agentic coding 与困难推理，成本更高。
    case pro = "deepseek-v4-pro"
}

@available(macOS 14.0, *)
@Model
public final class AppSettings {
    /// 永远为 1 的单行设置表。
    @Attribute(.unique) public var singletonID: Int
    public var policyModeRaw: String
    public var sandboxModeRaw: String
    public var telemetryEnabled: Bool
    public var sidecarVersion: String?
    /// 默认模型 id。可选而非非可选：SwiftData 轻量迁移要求新字段可空或有声明级默认值，
    /// 否则旧 store 读取会失败。nil 一律按 `AgentModel.flash` 回落（见 agentModel）。
    public var modelRaw: String?

    public init(singletonID: Int = 1,
                policyMode: PolicyMode = .strict,
                sandboxMode: SandboxMode = .workspaceWrite,
                telemetryEnabled: Bool = false,
                sidecarVersion: String? = nil,
                model: AgentModel = .flash) {
        self.singletonID = singletonID
        self.policyModeRaw = policyMode.rawValue
        self.sandboxModeRaw = sandboxMode.rawValue
        self.telemetryEnabled = telemetryEnabled
        self.sidecarVersion = sidecarVersion
        self.modelRaw = model.rawValue
    }

    public var policyMode: PolicyMode {
        get { PolicyMode(rawValue: policyModeRaw) ?? .strict }
        set { policyModeRaw = newValue.rawValue }
    }

    public var sandboxMode: SandboxMode {
        get { SandboxMode(rawValue: sandboxModeRaw) ?? .workspaceWrite }
        set { sandboxModeRaw = newValue.rawValue }
    }

    /// 未知/缺失的 modelRaw 一律回落 `.flash`（fail-soft：模型选择是偏好，不是安全边界）。
    public var agentModel: AgentModel {
        get { modelRaw.flatMap(AgentModel.init(rawValue:)) ?? .flash }
        set { modelRaw = newValue.rawValue }
    }
}
