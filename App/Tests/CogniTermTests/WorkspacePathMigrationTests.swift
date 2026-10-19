import XCTest
@testable import CogniTerm

/// 旧版路径输入框残留的修复回归。
///
/// 背景：早期「工作区」是自由输入框，输入 `log` 会被解析成 `$HOME/log` 并静默把工作区
/// 带到一个放日志的目录（还会建一个同名空目录）。输入框已经删掉（只能走 NSOpenPanel），
/// 但当时写进 UserDefaults 的那个值还在，实测本机就是 `workspacePath = /Users/me/log`：
/// 侧栏顶着一行 `~/log`、终端起在 `~/log`、历史会话列表也只看得见那批会话。
final class WorkspacePathMigrationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "workspace-migration-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    private var legacyPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("log", isDirectory: true)
            .path
    }

    func testRepairsLegacyLogPathToDefault() {
        var path = legacyPath
        let repaired = WorkspacePaths.repairLegacyResidue(&path, defaults: defaults)

        XCTAssertTrue(repaired)
        XCTAssertEqual(path, WorkspacePaths.defaultWorkspaceURL().path)
        XCTAssertNotEqual(path, legacyPath)
    }

    /// 只认这一个已知产物：用户自己选过的任何别的路径都不许碰。
    func testLeavesOtherPathsAlone() {
        var path = "/Users/me/work/CogniTerm"
        XCTAssertFalse(WorkspacePaths.repairLegacyResidue(&path, defaults: defaults))
        XCTAssertEqual(path, "/Users/me/work/CogniTerm")

        var empty = ""
        XCTAssertFalse(WorkspacePaths.repairLegacyResidue(&empty, defaults: defaults))
        XCTAssertEqual(empty, "")
    }

    /// 一次性：标记落盘后，即使用户后来又（故意）选了 `~/log`，也不该再被改回去。
    func testRepairHappensOnlyOnce() {
        var path = legacyPath
        XCTAssertTrue(WorkspacePaths.repairLegacyResidue(&path, defaults: defaults))

        var again = legacyPath
        XCTAssertFalse(WorkspacePaths.repairLegacyResidue(&again, defaults: defaults))
        XCTAssertEqual(again, legacyPath, "第二次不应再改写，否则用户的选择会被反复覆盖")
    }
}
