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

    @MainActor
    func testApprovalRulesFeedPolicyEngine() throws {
        let container = try PersistenceStack.inMemoryContainer()
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
