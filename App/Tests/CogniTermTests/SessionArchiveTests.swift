import XCTest
@testable import CogniTerm
import SessionLogReader

/// `SessionArchive` 的解码链路：**多帧 zstd** 是这里唯一的真风险。
///
/// 背景：dsh 每次追加都写一个新帧，`zlib.zstdDecompressSync` 只解第一帧
/// （实测 11KB 的会话只出 169 字节）。`SessionArchive` 用一个几十行的帧切分脚本
/// 逐帧解压后拼接——这个测试用 node 现造一个三帧文件，断言三帧内容**全都**回来了。
///
/// 开发期另有一份更强的验证：`tools/verify-session-decode.js` 拿 homebrew 的 `zstd`
/// 当外部判据，对 123 个真实会话逐字节比对（0 处不一致）。
final class SessionArchiveTests: XCTestCase {

    /// 找一台能跑 node 的机器；找不到就跳过（CI/精简环境）。
    private func nodePath() throws -> String {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/runtime/node-darwin-arm64/bin/node"),
            URL(fileURLWithPath: "/Applications/CogniTerm.app/Contents/Resources/runtime/node-darwin-arm64/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
        ]
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url.path
        }
        throw XCTSkip("本机没有可用的 node，跳过 zstd 解码链路测试")
    }

    private func run(_ node: String, _ args: [String]) throws -> (Data, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, errData)
    }

    private var tempDir: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("session-archive-\(UUID().uuidString)", isDirectory: true)
    }

    /// 用内嵌脚本解一个**三帧**文件，断言三帧全在。
    func testEmbeddedScriptDecodesEveryFrame() throws {
        let node = try nodePath()
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("session-decode.js")
        try Data(SessionArchive.decoderScript.utf8).write(to: script)

        // 造三帧：node 每调一次 zstdCompressSync 就是一帧，直接拼起来。
        let lines = ["{\"type\":\"session\",\"version\":4}", "{\"type\":\"a\"}", "{\"type\":\"b\"}"]
        let fixture = dir.appendingPathComponent("session.v4.jsonl.zstd")
        let maker = dir.appendingPathComponent("make.js")
        try Data("""
        const fs = require('fs');
        const zlib = require('zlib');
        const lines = \(try String(data: JSONSerialization.data(withJSONObject: lines), encoding: .utf8)!);
        const frames = lines.map((l) => zlib.zstdCompressSync(Buffer.from(l + '\\n')));
        fs.writeFileSync(process.argv[2], Buffer.concat(frames));
        """.utf8).write(to: maker)

        let (_, mkErr) = try run(node, [maker.path, fixture.path])
        XCTAssertTrue(mkErr.isEmpty, "夹具生成失败：\(String(decoding: mkErr, as: UTF8.self))")

        let (data, err) = try run(node, [script.path, fixture.path])
        XCTAssertTrue(err.isEmpty, "解码报错：\(String(decoding: err, as: UTF8.self))")

        let text = String(decoding: data, as: UTF8.self)
        let decoded = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(decoded, lines, "只解第一帧时这里只会剩 session 行")

        // 与 JSONL 解析接上：三帧 → 三条事件。
        let events = JSONLFile.parseAll(data: data)
        XCTAssertEqual(events.count, 3)
    }

    /// 单帧文件也必须能读（新会话只有 header，某些 dsh 版本不追加第二帧）。
    func testSingleFrameStillDecodes() throws {
        let node = try nodePath()
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("session-decode.js")
        try Data(SessionArchive.decoderScript.utf8).write(to: script)

        let fixture = dir.appendingPathComponent("one.jsonl.zstd")
        let maker = dir.appendingPathComponent("make1.js")
        try Data("""
        const fs = require('fs');
        const zlib = require('zlib');
        fs.writeFileSync(process.argv[2], zlib.zstdCompressSync(Buffer.from('{"type":"session"}\\n')));
        """.utf8).write(to: maker)

        _ = try run(node, [maker.path, fixture.path])
        let (data, _) = try run(node, [script.path, fixture.path])
        XCTAssertEqual(JSONLFile.parseAll(data: data).count, 1)
    }

    /// 解压出来的字节必须是**裸 JSONL**：SessionReducer 只认这个。
    func testScriptEmitsPlainJSONLWithoutNoise() throws {
        let node = try nodePath()
        let dir = tempDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("session-decode.js")
        try Data(SessionArchive.decoderScript.utf8).write(to: script)

        let fixture = dir.appendingPathComponent("x.jsonl.zstd")
        let maker = dir.appendingPathComponent("make2.js")
        try Data("""
        const fs = require('fs');
        const zlib = require('zlib');
        const parts = ['{"type":"session"}', '{"type":"user"}'].map((l) => zlib.zstdCompressSync(Buffer.from(l + '\\n')));
        fs.writeFileSync(process.argv[2], Buffer.concat(parts));
        """.utf8).write(to: maker)

        _ = try run(node, [maker.path, fixture.path])
        let (data, err) = try run(node, [script.path, fixture.path])
        XCTAssertTrue(err.isEmpty)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("frame decode failed"), "脚本自己的诊断不能混进 stdout")
        XCTAssertEqual(text, "{\"type\":\"session\"}\n{\"type\":\"user\"}\n")
    }
}
