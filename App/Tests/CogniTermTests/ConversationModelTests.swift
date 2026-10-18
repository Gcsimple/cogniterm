import XCTest
@testable import CogniTerm
import AcpClient
import PolicyEngine

/// ConversationModel 展示面归约与审批策略回归。
@MainActor
final class ConversationModelTests: XCTestCase {

    /// session/update 归约：消息合并、工具调用行、plan、usage。
    func testNotificationReduction() throws {
        let model = ConversationModel()

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "agent_message_chunk",
            "messageId": "m1",
            "content": ["type": "text", "text": "第一段，"],
        ]))
        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "agent_message_chunk",
            "messageId": "m1",
            "content": ["type": "text", "text": "第二段。"],
        ]))
        let assistant = try XCTUnwrap(model.rows.first { $0.kind == .assistant })
        XCTAssertEqual(assistant.text, "第一段，第二段。")

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-1",
            "title": "bash",
            "kind": "other",
            "status": "in_progress",
            "rawInput": ["command": "ls -la"],
        ]))
        let toolRow = try XCTUnwrap(model.rows.first { $0.kind == .tool })
        XCTAssertEqual(toolRow.text, "bash · ls -la")

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-1",
            "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": "8 items"]]],
        ]))
        XCTAssertEqual(model.rows.first { $0.kind == .tool }?.status, "completed")
        XCTAssertTrue(model.rows.first { $0.kind == .tool }?.text.contains("→ 8 items") == true)

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "plan",
            "entries": [["content": "读代码", "status": "completed"]],
        ]))
        XCTAssertEqual(model.rows.first { $0.kind == .plan }?.text, "✅ 读代码")

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "usage_update", "used": 100, "size": 128000,
        ]))
        XCTAssertEqual(model.usage?.used, 100)

        // beginSession 清空展示面与关联缓存。
        model.beginSession()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.usage)
        XCTAssertNil(model.toolCalls.snapshot(for: "tc-1"))
    }

    /// rules 模式：命中规则自动放行，不挂审批卡（命令文本经 tracker 补给）。
    func testRulesModeAutoAllowsMatchedCommand() async throws {
        let model = ConversationModel()
        model.policyMode = .rules
        model.ruleSet = RuleSet(rules: [
            ApprovalRule(tool: "bash", pattern: "rm -rf *", workspaceScoped: false),
        ])
        // tool_call 先行（真实路径由连接层分帧记录）。
        let event = try JSONDecoder.acp.decode(SessionUpdateEvent.self, from: frame([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-9",
            "title": "bash",
            "rawInput": ["command": "rm -rf build/"],
        ]))
        model.toolCalls.record(event)

        let broker = PermissionBroker(answerer: model.makeAnswerer())
        let result = try await broker.handleServerRequest(
            method: AcpMethod.requestPermission,
            params: try JSONEncoder.acp.encode(permissionParams(toolCallId: "tc-9"))
        )
        let response = try JSONDecoder.acp.decode(PermissionResponse.self,
                                                  from: try XCTUnwrap(result))
        XCTAssertEqual(response.status, .selected)
        XCTAssertEqual(response.optionId, "allow-once")
        XCTAssertNil(model.pendingPermission)
        XCTAssertTrue(model.rows.contains { $0.kind == .system && $0.text.contains("规则命中自动允许") })
    }

    /// rules 模式：命令关联不上（无 tool_call 事件）→ fail-closed 进审批卡。
    func testRulesModeFallsBackToCardWhenNoCommand() async throws {
        let model = ConversationModel()
        model.policyMode = .rules
        model.ruleSet = RuleSet(rules: [
            ApprovalRule(tool: "bash", pattern: "rm -rf *", workspaceScoped: false),
        ])

        let broker = PermissionBroker(answerer: model.makeAnswerer())
        let answerTask = Task { @MainActor in
            try? await broker.handleServerRequest(
                method: AcpMethod.requestPermission,
                params: try JSONEncoder.acp.encode(permissionParams(toolCallId: "tc-unknown"))
            )
        }

        try await waitUntil { model.pendingPermission != nil }
        let pending = try XCTUnwrap(model.pendingPermission)
        XCTAssertFalse(pending.hasCommandText)
        model.respond(.reject())
        _ = await answerTask.value
    }

    /// closed 模式：一律拒绝，不挂卡。
    func testClosedModeRejectsAll() async throws {
        let model = ConversationModel()
        model.policyMode = .closed

        let broker = PermissionBroker(answerer: model.makeAnswerer())
        let result = try await broker.handleServerRequest(
            method: AcpMethod.requestPermission,
            params: try JSONEncoder.acp.encode(permissionParams(toolCallId: "tc-1"))
        )
        let response = try JSONDecoder.acp.decode(PermissionResponse.self,
                                                  from: try XCTUnwrap(result))
        XCTAssertEqual(response.optionId, "reject-once")
        XCTAssertNil(model.pendingPermission)
    }

    /// strict 模式：挂卡等待用户。
    func testStrictModeShowsCard() async throws {
        let model = ConversationModel()
        model.policyMode = .strict

        let broker = PermissionBroker(answerer: model.makeAnswerer())
        let answerTask = Task { @MainActor in
            try? await broker.handleServerRequest(
                method: AcpMethod.requestPermission,
                params: try JSONEncoder.acp.encode(permissionParams(toolCallId: "tc-1"))
            )
        }
        try await waitUntil { model.pendingPermission != nil }
        model.respond(.cancel())
        _ = await answerTask.value
        XCTAssertTrue(model.rows.contains { $0.kind == .system && $0.text.contains("审批已取消") })
    }

    // MARK: - 终端命令审批门（MCP run_in_terminal，2026-10-18）

    /// strict：requestTerminalCommand 挂卡，allow → completion(.allow)。
    func testTerminalGateStrictShowsCardAndAllows() throws {
        let model = ConversationModel()
        model.policyMode = .strict
        var decision: TerminalCommandDecision?
        model.requestTerminalCommand("ls -la", target: "本地") { decision = $0 }

        let pending = try XCTUnwrap(model.pendingTerminalCommand)
        XCTAssertEqual(pending.command, "ls -la")
        XCTAssertNil(decision, "卡片挂着，不能提前给答案")

        model.respondTerminalCommand(allow: true)
        XCTAssertEqual(decision, .allow)
        XCTAssertNil(model.pendingTerminalCommand)
        XCTAssertTrue(model.rows.contains { $0.kind == .system && $0.text.contains("已允许") })
    }

    /// strict：reject → completion(.reject)，命令不执行。
    func testTerminalGateReject() throws {
        let model = ConversationModel()
        var decision: TerminalCommandDecision?
        model.requestTerminalCommand("rm -rf build", target: "本地") { decision = $0 }
        model.respondTerminalCommand(allow: false)
        XCTAssertEqual(decision, .reject)
        XCTAssertTrue(model.rows.contains { $0.kind == .system && $0.text.contains("已拒绝") })
    }

    /// closed：立即拒绝，不挂卡（fail-closed 的默认形态）。
    func testTerminalGateClosedRejectsImmediately() throws {
        let model = ConversationModel()
        model.policyMode = .closed
        var decision: TerminalCommandDecision?
        model.requestTerminalCommand("ls", target: "本地") { decision = $0 }
        XCTAssertEqual(decision, .reject)
        XCTAssertNil(model.pendingTerminalCommand)
    }

    /// rules：命中规则自动放行，不挂卡（与 ACP 审批卡同一心智）。
    func testTerminalGateRulesAutoAllows() throws {
        let model = ConversationModel()
        model.policyMode = .rules
        model.ruleSet = RuleSet(rules: [
            ApprovalRule(tool: TerminalMCP.toolName, pattern: "ls *", workspaceScoped: false),
        ])
        var decision: TerminalCommandDecision?
        model.requestTerminalCommand("ls -la", target: "本地") { decision = $0 }
        XCTAssertEqual(decision, .allow)
        XCTAssertNil(model.pendingTerminalCommand)
        XCTAssertTrue(model.rows.contains { $0.kind == .system && $0.text.contains("规则命中自动允许") })

        // 不命中：照样挂卡（fail-closed，不猜）。
        var second: TerminalCommandDecision?
        model.requestTerminalCommand("rm -rf /", target: "本地") { second = $0 }
        XCTAssertNil(second)
        XCTAssertNotNil(model.pendingTerminalCommand)
    }

    /// 新会话作废挂起的终端审批：fail-closed（completion(.reject)），不执行。
    func testTerminalGateBeginSessionCancelsPending() throws {
        let model = ConversationModel()
        var decision: TerminalCommandDecision?
        model.requestTerminalCommand("ls", target: "本地") { decision = $0 }
        model.beginSession()
        XCTAssertEqual(decision, .reject)
        XCTAssertNil(model.pendingTerminalCommand)
    }

    // MARK: - helpers

    private func permissionParams(toolCallId: String) -> PermissionRequestParams {
        PermissionRequestParams(
            sessionId: "s1",
            toolCall: ToolCall(toolCallId: toolCallId),
            options: [
                PermissionOption(optionId: "allow-once", name: "允许一次", kind: "allow_once"),
                PermissionOption(optionId: "reject-once", name: "拒绝", kind: "reject_once"),
            ]
        )
    }

    private func frame(_ object: [String: Any]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// session/update 通知的 params 线格式：{sessionId, update}（dsh 0.2 实测）。
    private func sessionFrame(_ update: [String: Any]) -> Data {
        frame(["sessionId": "s1", "update": update])
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ predicate: @MainActor @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件等待超时")
    }

    // MARK: - 工具结果折叠（2026-10-17：长输出不再淹进对话流）

    /// 长结果：行内只放 6 行预览 + 余量标注，完整文本留档可展开。
    func testLongToolResultIsFoldedWithPreviewAndExpands() throws {
        let model = ConversationModel()
        let longResult = (1...30).map { "line \($0)" }.joined(separator: "\n")

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-long",
            "title": "bash",
            "kind": "other",
            "status": "in_progress",
            "rawInput": ["command": "npm run build"],
        ]))
        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-long",
            "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": longResult]]],
        ]))

        let row = try XCTUnwrap(model.rows.first { $0.kind == .tool })
        // 预览 = 前 6 行 + 余量标注；30 行原文不能整个躺在对话流里。
        XCTAssertTrue(row.text.contains("line 1"), "预览要含首行：\n\(row.text)")
        XCTAssertTrue(row.text.contains("line 6"), "预览要含第 6 行：\n\(row.text)")
        XCTAssertFalse(row.text.contains("line 30"), "第 30 行不该出现在预览里：\n\(row.text)")
        XCTAssertTrue(row.text.contains("余 24 行"), "要标注余量：\n\(row.text)")
        // 完整文本留档，默认折叠。
        XCTAssertEqual(row.fullResult, longResult)
        XCTAssertFalse(model.isResultExpanded(row.id))

        model.toggleResultExpansion(row.id)
        XCTAssertTrue(model.isResultExpanded(row.id))
        model.toggleResultExpansion(row.id)
        XCTAssertFalse(model.isResultExpanded(row.id))

        // 新会话要清掉展开态（行 id 全部换新，留着就是泄漏）。
        model.toggleResultExpansion(row.id)
        model.beginSession()
        XCTAssertTrue(model.expandedResultRows.isEmpty)
    }

    /// 短结果不折叠：fullResult 保持 nil，原文整个在行里。
    func testShortToolResultIsNotFolded() throws {
        let model = ConversationModel()

        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "tool_call",
            "toolCallId": "tc-short",
            "title": "read",
            "kind": "other",
            "status": "in_progress",
            "rawInput": ["file_path": "/tmp/a.swift"],
        ]))
        model.handleNotification(method: AcpMethod.sessionUpdate, data: sessionFrame([
            "sessionUpdate": "tool_call_update",
            "toolCallId": "tc-short",
            "status": "completed",
            "content": [["type": "content", "content": ["type": "text", "text": "ok"]]],
        ]))

        let row = try XCTUnwrap(model.rows.first { $0.kind == .tool })
        XCTAssertEqual(row.fullResult, nil, "短结果不值得折叠，不留 fullResult")
        XCTAssertTrue(row.text.contains("→ ok"))
    }

    /// 预览纯函数的边界：恰好等于阈值不截断；超一行才截断且余量算对。
    func testResultPreviewBoundary() {
        let exactly = (1...6).map { "l\($0)" }.joined(separator: "\n")
        XCTAssertEqual(ConversationModel.resultPreview(exactly), exactly, "恰好 6 行不截断")

        let seven = exactly + "\nl7"
        let preview = ConversationModel.resultPreview(seven)
        XCTAssertTrue(preview.hasPrefix(exactly), "截断要保留前 6 行")
        XCTAssertTrue(preview.contains("余 1 行"), "余量要算对，实际：\(preview)")
        XCTAssertFalse(preview.contains("l7\n"), "第 7 行本体不进预览（只在余量标注里计数）")

        // 行数少但字符超阈值（单行巨长）同样要截断。
        let oneGiantLine = String(repeating: "x", count: 601)
        XCTAssertTrue(ConversationModel.resultPreview(oneGiantLine).contains("…"), "超长单行也要截断")
    }
}
