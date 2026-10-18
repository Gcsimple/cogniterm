import XCTest
@testable import CogniTerm
import AcpClient

/// DemoPeer 全链路回归：握手 → 会话 → 流式更新 → 反向审批 → 收尾 → 第二轮（usage/plan）。
/// 重点回归 tool_call 与 request_permission 的保序（连接层分帧路径同步记录快照）。
@MainActor
final class DemoPeerFlowTests: XCTestCase {

    func testDemoPeerFullFlow() async throws {
        let conversation = ConversationModel()
        // 与 SidecarService.startDemo 同构：transport 自持，DemoPeer 必须强引用
        // （LoopbackTransport.responder 只 weak 捕获对端）。
        let transport = LoopbackTransport()
        let peer = DemoPeer(transport: transport)
        let client = DshAcpClient(transport: transport, toolCallTracker: conversation.toolCalls)
        let broker = PermissionBroker()
        await broker.setAnswerer(conversation.makeAnswerer())

        // 模拟 SidecarService.observeNotifications 的消费路径（独立 Task）。
        let collector = Task { @MainActor in
            for await note in await client.connection.notifications {
                conversation.handleNotification(method: note.method, data: note.params)
            }
        }
        defer { collector.cancel() }

        try await client.start(serverHandler: broker)
        let initResult = try await client.initialize(clientName: "CogniTerm", clientVersion: "test")
        XCTAssertEqual(initResult.serverInfo.name, "dsh-demo-peer")
        XCTAssertEqual(initResult.protocolVersion, 1)

        let session = try await client.newSession(cwd: URL(fileURLWithPath: NSTemporaryDirectory()))
        let sid = try XCTUnwrap(session.sessionId)

        // 第一轮：流式消息 + tool_call + 审批请求。
        conversation.appendUser("清理构建产物")
        conversation.setWorking(true)
        let first = try await client.prompt(sessionId: sid, text: "清理构建产物")
        XCTAssertEqual(first.stopReason, "request_permission")
        // 与 ComposerView.send 一致：prompt 返回即复位工作态（stopReason 交给展示面处理）。
        conversation.handlePromptResult(first)
        XCTAssertFalse(conversation.isWorking)

        // 审批卡挂起，且命令文本已被 tool_call 事件补给（保序回归点）。
        try await waitUntil { conversation.pendingPermission != nil }
        let pending = try XCTUnwrap(conversation.pendingPermission)
        XCTAssertEqual(pending.commandText, "rm -rf build/")
        XCTAssertEqual(pending.toolName, "bash")
        XCTAssertTrue(pending.hasCommandText)

        // 允许 → tool_call_update(completed) + 收尾消息。
        conversation.respond(.allow())

        try await waitUntil(timeout: 3) {
            conversation.rows.contains { $0.kind == .tool && $0.status == "completed" }
        }
        let toolRow = try XCTUnwrap(conversation.rows.first { $0.kind == .tool })
        XCTAssertEqual(toolRow.text, "bash · rm -rf build/\n→ 已删除 build/（演示）")

        // 第二轮：plan + usage + end_turn。
        let second = try await client.prompt(sessionId: sid, text: "继续")
        XCTAssertEqual(second.stopReason, "end_turn")
        conversation.handlePromptResult(second)

        try await waitUntil(timeout: 3) { conversation.usage != nil }
        XCTAssertEqual(conversation.usage?.used, 1840)
        XCTAssertEqual(conversation.usage?.size, 128000)

        // 流式消息按 messageId 合并。
        XCTAssertTrue(conversation.rows.contains {
            $0.kind == .assistant && $0.text.contains("收到。我先检查一下工作区，然后给出计划。")
        })
        // plan 行。
        XCTAssertTrue(conversation.rows.contains { $0.kind == .plan && $0.text.contains("检查工作区状态") })
        // 系统行：允许回执。
        XCTAssertTrue(conversation.rows.contains { $0.kind == .system && $0.text.contains("已允许") })
        // 第一轮结束工作态复位。
        XCTAssertFalse(conversation.isWorking)
    }

    // MARK: - helpers

    private func waitUntil(timeout: TimeInterval = 2,
                           _ predicate: @MainActor @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("条件等待超时")
    }
}
