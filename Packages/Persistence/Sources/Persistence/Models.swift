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

@available(macOS 14.0, *)
@Model
public final class AppSettings {
    /// 永远为 1 的单行设置表。
    @Attribute(.unique) public var singletonID: Int
    public var policyModeRaw: String
    public var sandboxModeRaw: String
    public var telemetryEnabled: Bool
    public var sidecarVersion: String?

    public init(singletonID: Int = 1,
                policyMode: PolicyMode = .strict,
                sandboxMode: SandboxMode = .workspaceWrite,
                telemetryEnabled: Bool = false,
                sidecarVersion: String? = nil) {
        self.singletonID = singletonID
        self.policyModeRaw = policyMode.rawValue
        self.sandboxModeRaw = sandboxMode.rawValue
        self.telemetryEnabled = telemetryEnabled
        self.sidecarVersion = sidecarVersion
    }

    public var policyMode: PolicyMode {
        get { PolicyMode(rawValue: policyModeRaw) ?? .strict }
        set { policyModeRaw = newValue.rawValue }
    }

    public var sandboxMode: SandboxMode {
        get { SandboxMode(rawValue: sandboxModeRaw) ?? .workspaceWrite }
        set { sandboxModeRaw = newValue.rawValue }
    }
}
