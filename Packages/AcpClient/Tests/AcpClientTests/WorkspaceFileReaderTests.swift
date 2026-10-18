import XCTest
@testable import AcpClient

final class WorkspaceFileReaderTests: XCTestCase {

    private var root: URL!
    private var reader: WorkspaceFileReader!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CogniTerm-fsreader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reader = WorkspaceFileReader(workspaceRoot: root.path, maxBytes: 1024)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testReadInsideWorkspace() throws {
        let file = root.appendingPathComponent("a.txt")
        try "l1\nl2\nl3\nl4".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try reader.read(path: file.path), "l1\nl2\nl3\nl4")
    }

    func testLineAndLimitSlicing() throws {
        let file = root.appendingPathComponent("b.txt")
        try "l1\nl2\nl3\nl4\nl5".write(to: file, atomically: true, encoding: .utf8)
        // 1-based：从第 2 行起读 2 行。
        XCTAssertEqual(try reader.read(path: file.path, line: 2, limit: 2), "l2\nl3")
        // limit 越界时截到文件尾，不抛错。
        XCTAssertEqual(try reader.read(path: file.path, line: 4, limit: 99), "l4\nl5")
        // 起始行越界返回空串。
        XCTAssertEqual(try reader.read(path: file.path, line: 99), "")
    }

    func testRejectsOutsideWorkspace() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).txt", isDirectory: false)
        try "secret".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        XCTAssertThrowsError(try reader.read(path: outside.path)) { error in
            XCTAssertEqual(error as? FileReadError, .outsideWorkspace(path: outside.path))
        }
    }

    func testRejectsDotDotTraversal() throws {
        let escaped = root.appendingPathComponent("../escape.txt").path
        XCTAssertThrowsError(try reader.read(path: escaped)) { error in
            guard let fr = error as? FileReadError, case .outsideWorkspace = fr else {
                XCTFail("应判越界，实际 \(error)")
                return
            }
        }
    }

    func testRejectsSymlinkEscape() throws {
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("link-target-\(UUID().uuidString).txt", isDirectory: false)
        try "secret".write(to: target, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: target) }

        let link = root.appendingPathComponent("sneaky.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try reader.read(path: link.path)) { error in
            guard let fr = error as? FileReadError, case .outsideWorkspace = fr else {
                XCTFail("symlink 越界应被拒绝，实际 \(error)")
                return
            }
        }
    }

    func testRejectsRelativePath() {
        XCTAssertThrowsError(try reader.read(path: "relative/a.txt")) { error in
            XCTAssertEqual(error as? FileReadError, .relativePath("relative/a.txt"))
        }
    }

    func testRejectsTooLarge() throws {
        let file = root.appendingPathComponent("big.txt")
        try String(repeating: "x", count: 2048).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try reader.read(path: file.path)) { error in
            guard let fr = error as? FileReadError, case .tooLarge(let bytes, let limit) = fr else {
                XCTFail("应判超大，实际 \(error)")
                return
            }
            XCTAssertEqual(bytes, 2048)
            XCTAssertEqual(limit, 1024)
        }
    }

    func testRejectsMissingFile() {
        XCTAssertThrowsError(try reader.read(path: root.appendingPathComponent("nope.txt").path)) { error in
            guard let fr = error as? FileReadError, case .unreadable = fr else {
                XCTFail("应判不可读，实际 \(error)")
                return
            }
        }
    }
}
