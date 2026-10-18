import XCTest
import SwiftData
@testable import Persistence
import PolicyEngine

@available(macOS 14.0, *)
final class PersistenceTests: XCTestCase {

    @MainActor
    func testWorkspaceAndSessionRoundtrip() throws {
        let container = try PersistenceStack.inMemoryContainer()
        let context = ModelContext(container)

        let workspace = Workspace(path: "/Users/me/projects/demo",
                                  name: "demo")
        let session = SessionRecord(acpSessionID: "acp-42",
                                    jsonlStem: "2026-10-12T01-00-00",
                                    stopReason: "end_turn",
                                    jsonlPath: "/tmp/log/2026-10-12T01-00-00.jsonl",
                                    title: "第一次会话",
                                    workspace: workspace)
        workspace.sessions = [session]
        context.insert(workspace)
        try context.save()

        let workspaces = try context.fetch(FetchDescriptor<Workspace>())
        XCTAssertEqual(workspaces.count, 1)
        let fetched = try XCTUnwrap(workspaces.first)
        XCTAssertEqual(fetched.path, "/Users/me/projects/demo")
        XCTAssertEqual(fetched.sessions.first?.acpSessionID, "acp-42")
        XCTAssertEqual(fetched.sessions.first?.stopReason, "end_turn")

        // 级联删除：删掉工作区，会话随之消失。
        context.delete(fetched)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Workspace>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SessionRecord>()), 0)
    }

    @MainActor
    func testAppSettingsSingletonAndEnums() throws {
        let container = try PersistenceStack.inMemoryContainer()
        let context = ModelContext(container)

        let settings = AppSettings(policyMode: .rules,
                                   sandboxMode: .readOnly,
                                   telemetryEnabled: false)
        context.insert(settings)
        try context.save()

        settings.policyMode = .closed
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AppSettings>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.policyMode, .closed)
        XCTAssertEqual(fetched.first?.sandboxMode, .readOnly)
        XCTAssertFalse(fetched.first?.telemetryEnabled ?? true)
    }

    /// 默认模型字段：往返 + 旧数据 / 陌生值回落。
    ///
    /// 两种必须回落到 flash 的真实场景：
    ///   1. nil —— SwiftData 轻量迁移补出的旧行（该列在旧 store 里不存在）；
    ///   2. 陌生字符串 —— 未来 dsh 模型目录里删掉某个 id 后本地残留的值。
    /// 另外 init 必须把默认值规范化写入 modelRaw（而不是留 nil），
    /// 这样新建行永远是合法值，落盘数据不依赖读路径兜底。
    @MainActor
    func testAgentModelRoundtripAndFallback() throws {
        let container = try PersistenceStack.inMemoryContainer()
        let context = ModelContext(container)

        let settings = AppSettings(model: .pro)
        context.insert(settings)
        try context.save()

        settings.agentModel = .flash
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).first?.agentModel, .flash)

        settings.agentModel = .pro
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<AppSettings>()).first?.agentModel, .pro)

        // 新建即规范化：默认档写的是合法 rawValue，不是 nil。
        let fresh = AppSettings()
        XCTAssertEqual(fresh.modelRaw, "deepseek-flash")
        XCTAssertEqual(fresh.agentModel, .flash)

        // 旧 store 行（轻量迁移补出的 nil）必须回落，且读路径不崩。
        let legacy = AppSettings()
        legacy.modelRaw = nil
        XCTAssertEqual(legacy.agentModel, .flash)

        // dsh 目录里已删除的模型 id 同样回落。
        legacy.modelRaw = "some-removed-model"
        XCTAssertEqual(legacy.agentModel, .flash)

        // 曾经写错的旧值（不在 dsh 目录、只靠网关别名能跑的 "deepseek-v4-flash"）
        // 也必须回落，不能让历史 store 卡在一个不在枚举里的值上。
        // 回落到的 .flash 与它其实是同一个模型（网关把该别名解析成 deepseek-flash），
        // 所以这是**无感**的规范化，不是模型被换掉。
        legacy.modelRaw = "deepseek-v4-flash"
        XCTAssertEqual(legacy.agentModel, .flash)

        // rawValue 是**上线的 wire model id**，必须与 vendored runtime 的
        // dsh-llm-deepseek DEFAULT_MODELS 目录 id 逐字一致（实测账号 /v1/models
        // 也只回这两个）。拼错的代价不是本地报错：modelInfo() 对目录外 id
        // 原样透传到服务端，而 dsh 还会为它合成一条重名选项污染选择器。
        XCTAssertEqual(AgentModel.flash.rawValue, "deepseek-flash")
        XCTAssertEqual(AgentModel.pro.rawValue, "deepseek-v4-pro")
    }

    @MainActor
    func testApprovalRulesFeedPolicyEngine() throws {        let container = try PersistenceStack.inMemoryContainer()
        let context = ModelContext(container)

        let rule = PolicyEngine.ApprovalRule(tool: "bash",
                                             pattern: "git status",
                                             workspaceScoped: false)
        context.insert(ApprovalRuleRecord(rule))
        try context.save()

        let records = try context.fetch(FetchDescriptor<ApprovalRuleRecord>())
        let ruleSet = RuleSet(rules: records.map(\.asPolicyRule))

        XCTAssertNotNil(ruleSet.automaticAllow(for:
            .init(tool: "bash", command: "git status")))
        // 持久化回来的规则仍然保持精确模板语义。
        XCTAssertNil(ruleSet.automaticAllow(for:
            .init(tool: "bash", command: "git push origin main")))
    }
}
