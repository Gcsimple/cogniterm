import XCTest
@testable import SessionLogReader

/// 「删掉一条历史会话」的回归。
///
/// 两条硬要求：
///   1. **可恢复**：走废纸篓，不是 `removeItem`。所以测试里换了一个假搬运工，
///      不去污染用户真实的 `~/.Trash`；生产路径（`moveToTrash`）只有那一行调用。
///   2. **删不到别处**：只认 `sessions/<cwd 编码>/<sessionId>`，目录名必须等于
///      sessionId，且必须在 sessions 根之下。
final class SessionStoreTests: XCTestCase {

    private var home: URL!
    private var fakeTrash: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("dsh-home-\(UUID().uuidString)", isDirectory: true)
        home = base
        fakeTrash = base.appendingPathComponent("fake-trash", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
        try super.tearDownWithError()
    }

    private var cacheRoot: URL {
        home.appendingPathComponent("storages/session_projcache/sessions", isDirectory: true)
    }

    @discardableResult
    private func makeSession(id: String,
                             title: String = "你好",
                             count: Int = 1,
                             cache: Bool = true) throws -> SessionSummary {
        let dir = home.appendingPathComponent("sessions/--Users-Admin-CogniTerm--/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x28, count: 2048)
            .write(to: dir.appendingPathComponent("session.v4.jsonl.zstd"))

        if cache {
            let root: [String: Any] = [
                "version": 7,
                "record": [
                    "identity": ["formatVersion": 4, "createdAt": 1_792_289_176_644,
                                 "cwd": "/Users/Admin/CogniTerm"],
                    "rows": ["title": ["ver": 1, "val": title],
                             "titleInput": ["ver": 3, "val": ["count": count]]],
                ],
            ]
            try JSONSerialization.data(withJSONObject: root)
                .write(to: cacheRoot.appendingPathComponent("\(id).json"))
        }

        return try XCTUnwrap(SessionIndex.load(dshHome: home).first { $0.sessionId == id })
    }

    /// 假搬运工：搬到 temp 下的 fake-trash，等价语义（原位置消失）但不碰真实废纸篓。
    private func mover(_ url: URL) throws -> URL {
        let landed = fakeTrash.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: landed)
        try FileManager.default.moveItem(at: url, to: landed)
        return landed
    }

    // MARK: 正常删除

    func testTrashMovesSessionDirectoryAndProjectionCache() throws {
        let summary = try makeSession(id: "AAA-111")
        let dir = summary.sessionDirectory

        let landed = try SessionStore.trash(summary, dshHome: home, move: mover)

        XCTAssertEqual(landed.count, 2, "会话目录 + 投影缓存")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "原位置必须空掉")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fakeTrash.appendingPathComponent("AAA-111").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fakeTrash.appendingPathComponent("AAA-111.json").path))
    }

    /// 删完必须从列表里消失——列表是按目录扫的，这就是「移走即隐藏」的判据。
    func testTrashedSessionDisappearsFromIndex() throws {
        let summary = try makeSession(id: "gone")
        _ = try makeSession(id: "kept")

        XCTAssertEqual(SessionIndex.load(dshHome: home).count, 2)
        try SessionStore.trash(summary, dshHome: home, move: mover)
        XCTAssertEqual(SessionIndex.load(dshHome: home).map(\.sessionId), ["kept"])
    }

    /// 投影缓存是派生数据，缺失不算失败（dsh 会重建）。
    func testMissingProjectionCacheIsNotAFailure() throws {
        let summary = try makeSession(id: "no-cache", cache: false)
        let landed = try SessionStore.trash(summary, dshHome: home, move: mover)
        XCTAssertEqual(landed.count, 1)
    }

    // MARK: 防线

    /// 目录不在 `sessions/` 之下 → 拒绝。防止 summary 被伪造/污染后删到用户别的目录。
    func testRefusesPathOutsideSessionsRoot() throws {
        let summary = try makeSession(id: "ok")
        let hostile = SessionSummary(
            sessionId: summary.sessionId,
            title: nil, cwd: nil, createdAt: nil, lastActivity: nil,
            userMessageCount: 1,
            trajectory: nil,
            sessionDirectory: home.appendingPathComponent("not-sessions/\(summary.sessionId)")
        )
        try FileManager.default.createDirectory(
            at: hostile.sessionDirectory, withIntermediateDirectories: true)

        XCTAssertThrowsError(try SessionStore.trash(hostile, dshHome: home, move: mover)) { error in
            guard case SessionStore.Failure.outsideSessionsRoot = error else {
                return XCTFail("应该是 outsideSessionsRoot，实际：\(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: hostile.sessionDirectory.path),
                      "拒绝时不能动任何东西")
    }

    /// 目录名和 sessionId 对不上 → 拒绝（这条挡住「拿别人的 id 去删另一个目录」）。
    func testRefusesWhenDirectoryNameDoesNotMatchSessionId() throws {
        let summary = try makeSession(id: "real")
        let mismatched = SessionSummary(
            sessionId: "claimed",
            title: nil, cwd: nil, createdAt: nil, lastActivity: nil,
            userMessageCount: 1,
            trajectory: nil,
            sessionDirectory: summary.sessionDirectory
        )

        XCTAssertThrowsError(try SessionStore.trash(mismatched, dshHome: home, move: mover))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.sessionDirectory.path))
    }

    /// 已经不存在（重复点删除）→ 抛错而不是静默成功，UI 才不会刷出个假结果。
    func testRefusesWhenDirectoryIsAlreadyGone() throws {
        let summary = try makeSession(id: "twice")
        try SessionStore.trash(summary, dshHome: home, move: mover)
        XCTAssertThrowsError(try SessionStore.trash(summary, dshHome: home, move: mover))
    }
}
