import XCTest
@testable import SessionLogReader

final class JSONLFileTests: XCTestCase {

    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessionlog-\(UUID().uuidString).jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        super.tearDown()
    }

    func testReadAllSkipsBadLinesAndNumbersSeq() throws {
        let content = """
        {"type":"a","n":1}\n
        not-json\n
        \n
        {"type":"b","n":2}\n
        """
        try content.data(using: .utf8)!.write(to: tempURL)

        let events = try JSONLFile.readAll(at: tempURL)
        XCTAssertEqual(events.map(\.seq), [0, 1])
        XCTAssertEqual(events.compactMap(\.kind), ["a", "b"])
    }

    func testTailerReceivesAppendedEvents() throws {
        try Data("{\"type\":\"session/start\"}\n".utf8).write(to: tempURL)

        let tailer = EventFileTailer(url: tempURL)
        let expectation = expectation(description: "收到事件")
        expectation.expectedFulfillmentCount = 3
        var received: [LogEvent] = []
        let queue = DispatchQueue(label: "test.tailer")
        tailer.onEvents = { events in
            queue.async {
                received.append(contentsOf: events)
                events.forEach { _ in expectation.fulfill() }
            }
        }
        try tailer.start()

        // 既有 1 条 + 追加 2 条（includingExisting 会先回灌既有内容）。
        let handle = try FileHandle(forWritingTo: tempURL)
        handle.seekToEndOfFile()
        handle.write(Data("{\"type\":\"assistant/text\",\"text\":\"hi\"}\n".utf8))
        handle.write(Data("{\"type\":\"turn/end\",\"stopReason\":\"end_turn\"}\n".utf8))

        wait(for: [expectation], timeout: 3)
        tailer.stop()
        XCTAssertEqual(received.map(\.kind), ["session/start", "assistant/text", "turn/end"])
    }

    func testTailerSurvivesRotation() throws {
        try Data("{\"type\":\"old\"}\n".utf8).write(to: tempURL)
        let tailer = EventFileTailer(url: tempURL)
        let rotated = expectation(description: "检测到轮转")
        let newEvent = expectation(description: "轮转后读到新文件事件")
        tailer.onRotation = { rotated.fulfill() }
        tailer.onEvents = { events in
            if events.contains(where: { $0.kind == "after-rotation" }) {
                newEvent.fulfill()
            }
        }
        try tailer.start()

        let renamed = tempURL.appendingPathExtension("old")
        try? FileManager.default.removeItem(at: renamed)
        try FileManager.default.moveItem(at: tempURL, to: renamed)
        try Data("{\"type\":\"after-rotation\"}\n".utf8).write(to: tempURL)

        wait(for: [rotated, newEvent], timeout: 3)
        tailer.stop()
        try? FileManager.default.removeItem(at: renamed)
    }
}
