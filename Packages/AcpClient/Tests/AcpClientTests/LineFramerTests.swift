import XCTest
@testable import AcpClient

final class LineFramerTests: XCTestCase {
    func testSplitsOnNewlineAndStripsCR() {
        let framer = LineFramer()
        let out = framer.append(Data("a\r\nb\nc".utf8))
        XCTAssertEqual(out.map { String(data: $0, encoding: .utf8) }, ["a", "b"])
        XCTAssertEqual(String(data: framer.leftover, encoding: .utf8), "c")
    }

    func testPartialDeliveryAcrossChunks() {
        let framer = LineFramer()
        XCTAssertTrue(framer.append(Data("{\"jsonrpc".utf8)).isEmpty)
        XCTAssertTrue(framer.append(Data(":\"2.0\"}\n".utf8)).count == 1)
    }

    func testMultipleFramesOneChunk() {
        let framer = LineFramer()
        let out = framer.append(Data("1\n2\n3\n".utf8))
        XCTAssertEqual(out.count, 3)
    }

    func testEmptyLinesAreDropped() {
        let framer = LineFramer()
        XCTAssertTrue(framer.append(Data("\n\n".utf8)).isEmpty)
    }
}
