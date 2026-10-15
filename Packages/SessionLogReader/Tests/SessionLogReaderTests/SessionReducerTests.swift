import XCTest
@testable import SessionLogReader

final class SessionReducerTests: XCTestCase {

    private func event(_ json: String) -> LogEvent {
        JSONLLine.parse(Data(json.utf8), seq: 0)!
    }

    func testAssistantStreamingTextMerges() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"assistant/text","messageId":"m1","text":"你好"}"#))
        SessionReducer.reduce(state: &state, event: event(#"{"type":"assistant/chunk","messageId":"m1","text":"，世界"}"#))

        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.messages.count, 1)
        XCTAssertEqual(state.messages.first?.text, "你好，世界")
    }

    func testContentBlocksShape() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"assistant/message","messageId":"m2","content":[{"type":"text","text":"块一"},{"type":"text","text":"块二"}]}"#))
        XCTAssertEqual(state.messages.first?.text, "块一块二")
    }

    func testToolCallLifecycleUpsert() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"tool/call","toolCall":{"id":"t1","title":"Bash","rawCommand":"git status","status":"pending"}}"#))
        SessionReducer.reduce(state: &state, event: event(#"{"type":"tool/result","toolCallId":"t1","status":"completed"}"#))

        XCTAssertEqual(state.toolCalls.count, 1)
        XCTAssertEqual(state.toolCalls.first?.command, "git status")
        XCTAssertEqual(state.toolCalls.first?.status, "completed")
    }

    func testApprovalAndEndTransitions() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"session/request_permission"}"#))
        XCTAssertEqual(state.status, .awaitingApproval)

        SessionReducer.reduce(state: &state, event: event(#"{"type":"approval/resolved"}"#))
        XCTAssertEqual(state.status, .running)

        SessionReducer.reduce(state: &state, event: event(#"{"type":"turn/end","data":{"stopReason":"end_turn"}}"#))
        XCTAssertEqual(state.status, .idle)
        XCTAssertEqual(state.stopReason, "end_turn")
    }

    func testCancelledAndErrorStopReasons() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"turn/end","data":{"stopReason":"cancelled"}}"#))
        XCTAssertEqual(state.status, .cancelled)

        SessionReducer.reduce(state: &state, event: event(#"{"type":"session/error","data":{"message":"boom"}}"#))
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.lastError, "boom")
    }

    func testPlanEntries() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"plan/update","entries":[{"type":"in_progress","content":"读代码"},{"type":"pending","content":"改代码"}]}"#))
        XCTAssertEqual(state.plan.map(\.title), ["读代码", "改代码"])
        XCTAssertEqual(state.plan.first?.status, "in_progress")
    }

    func testUnknownEventDoesNotCrashOrMutate() {
        var state = SessionViewState()
        SessionReducer.reduce(state: &state, event: event(#"{"type":"future/unknown","anything":true}"#))
        XCTAssertEqual(state, SessionViewState())
    }
}
