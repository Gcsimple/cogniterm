import XCTest
@testable import SessionLogReader

/// `SessionIndex` 的回归：它是「历史会话能不能被认出来」的唯一数据源。
///
/// 这些断言都建立在**真实落盘布局**上（`sessions/<cwd>/<id>/session.v*.jsonl.zstd`
/// + `storages/session_projcache/sessions/<id>.json`），fixture 按同样的形状造。
final class SessionIndexTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: cacheRoot, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private var cacheRoot: URL {
        home.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
    }

    /// 按真实布局造一个会话目录，返回 sessionId。
    @discardableResult
    private func makeSession(id: String,
                             title: String?,
                             count: Int,
                             cwd: String = "/Users/Admin/CogniTerm",
                             createdAt ms: Double = 1_792_289_176_644,
                             trajectoryBytes: Int = 2048,
                             modified: Date = Date(timeIntervalSince1970: 1_792_300_000),
                             cache: Bool = true,
                             malformedCache: Bool = false,
                             workspaceDir: String = "--Users-Admin-CogniTerm--") throws -> String {
        let dir = home
            .appendingPathComponent("sessions/\(workspaceDir)/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 轨迹内容本身无关紧要（这里不解压），但**大小**参与空会话兜底判定。
        let blob = Data(repeating: 0x28, count: trajectoryBytes)
        let file = dir.appendingPathComponent("session.v4.jsonl.zstd")
        try blob.write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        if malformedCache {
            try Data("{ not json".utf8)
                .write(to: cacheRoot.appendingPathComponent("\(id).json"))
        } else if cache {
            let rows: [String: Any] = [
                "title": ["ver": 1, "seq": 25, "val": title as Any],
                "titleInput": ["ver": 3, "seq": 25,
                               "val": ["count": count, "lastSeq": 17]],
            ]
            let root: [String: Any] = [
                "version": 7,
                "record": [
                    "identity": ["formatVersion": 4, "createdAt": ms, "cwd": cwd],
                    "rows": rows,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: root)
            try data.write(to: cacheRoot.appendingPathComponent("\(id).json"))
        }
        return id
    }

    // MARK: 标题与时间

    func testListsTitleAndTimeFromProjectionCache() throws {
        let id = try makeSession(id: "AAA-111", title: "目录下有什么文件", count: 2)

        let list = SessionIndex.load(dshHome: home)
        XCTAssertEqual(list.count, 1)
        let item = try XCTUnwrap(list.first)
        XCTAssertEqual(item.sessionId, id)
        XCTAssertEqual(item.title, "目录下有什么文件")
        XCTAssertEqual(item.displayTitle, "目录下有什么文件")
        XCTAssertEqual(item.cwd, "/Users/Admin/CogniTerm")
        XCTAssertEqual(item.userMessageCount, 2)
        XCTAssertFalse(item.isBlank)
        XCTAssertEqual(item.createdAt?.timeIntervalSince1970 ?? 0, 1_792_289_176.644, accuracy: 0.01)
        XCTAssertEqual(item.lastActivity?.timeIntervalSince1970 ?? 0, 1_792_300_000, accuracy: 0.01)
        XCTAssertNotNil(item.trajectory)
    }

    /// 这轮要修的核心问题：**任何情况下都不能把 UUID 当标题显示**。
    func testDisplayTitleNeverFallsBackToUUID() throws {
        // 有 projcache（知道 3 条用户消息）但没有标题：dsh 的 title 行可能是 nil
        // （我们关掉了 session-title-llm），这时不能退回 UUID。
        try makeSession(id: "9C2AD0DF-7A56-4320-8545-221F43BBBF36",
                        title: nil, count: 3)

        let item = try XCTUnwrap(SessionIndex.load(dshHome: home).first)
        XCTAssertEqual(item.displayTitle, "未命名会话 · 3 轮")
        XCTAssertFalse(item.displayTitle.contains("9C2AD0DF"))
    }

    func testBlankSessionWithNoCacheFallsBackToTrajectorySize() throws {
        // projcache 缺失是允许的（它是缓存）。此时只能看轨迹大小：
        // 只有 header 的文件约 150 字节，超过 400 才认为有内容。
        try makeSession(id: "small", title: nil, count: 0, trajectoryBytes: 150, cache: false)
        try makeSession(id: "big", title: nil, count: 0, trajectoryBytes: 4096, cache: false)

        let list = SessionIndex.load(dshHome: home)
        XCTAssertEqual(list.map(\.sessionId).sorted(), ["big"])
        XCTAssertEqual(list.first?.userMessageCount, 1, "无 projcache 时按有内容降级，不能当成 0 轮")
    }

    // MARK: 空会话

    func testBlankSessionsAreHiddenByDefault() throws {
        try makeSession(id: "used", title: "你好", count: 1)
        try makeSession(id: "blank-1", title: nil, count: 0, trajectoryBytes: 156)

        XCTAssertEqual(SessionIndex.load(dshHome: home).map(\.sessionId), ["used"])

        let withBlank = SessionIndex.load(dshHome: home, includeBlank: true)
        XCTAssertEqual(withBlank.count, 2)
        XCTAssertEqual(withBlank.filter(\.isBlank).map(\.sessionId), ["blank-1"])
        XCTAssertEqual(withBlank.first(where: { $0.isBlank })?.displayTitle, "空会话")
    }

    // MARK: 排序与容错

    func testSortsByLastActivityDescending() throws {
        try makeSession(id: "old", title: "旧", count: 1,
                        modified: Date(timeIntervalSince1970: 1_000))
        try makeSession(id: "new", title: "新", count: 1,
                        modified: Date(timeIntervalSince1970: 9_000))

        XCTAssertEqual(SessionIndex.load(dshHome: home).map(\.sessionId), ["new", "old"])
    }

    func testMalformedCacheDegradesInsteadOfThrowing() throws {
        try makeSession(id: "broken", title: "x", count: 1, malformedCache: true)

        let item = try XCTUnwrap(SessionIndex.load(dshHome: home).first)
        XCTAssertNil(item.title, "坏缓存只丢标题，不能整条消失")
        XCTAssertEqual(item.userMessageCount, 1, "按轨迹大小兜底")
    }

    func testMissingHomeReturnsEmpty() {
        let missing = home.appendingPathComponent("nope", isDirectory: true)
        XCTAssertTrue(SessionIndex.load(dshHome: missing).isEmpty)
    }

    /// 多版本轨迹共存时取最新的那个（dsh 升级格式后会同时留着旧文件）。
    func testPicksNewestTrajectoryVersion() throws {
        let id = try makeSession(id: "multi", title: "多版本", count: 1)
        let dir = home.appendingPathComponent("sessions/--Users-Admin-CogniTerm--/\(id)")
        let v3 = dir.appendingPathComponent("session.v3.jsonl.zstd")
        try Data(repeating: 1, count: 2048).write(to: v3)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 500_000)], ofItemAtPath: v3.path
        )

        let item = try XCTUnwrap(SessionIndex.load(dshHome: home).first)
        XCTAssertEqual(item.trajectory?.lastPathComponent, "session.v4.jsonl.zstd")
    }
}
