import XCTest
@testable import CogniTerm
import TerminalCore

/// 密码存取的 Keychain 往返。
///
/// 用 `unit-test.invalid` 这个必然不存在的目标做隔离：它不会与任何真实主机
/// 的密码撞账，跑完立刻删掉。**这条测试会真的碰用户的钥匙串**——所以只在
/// 明确需要验证 Keychain 通路时保留，且每一步都可逆。
final class SSHPasswordStoreTests: XCTestCase {

    private var target: SSHTarget {
        SSHTarget(host: "unit-test.invalid", port: 22, username: "cogniterm-unit-test")
    }

    override func tearDown() {
        SSHPasswordStore.removePassword(for: target)
        super.tearDown()
    }

    /// 同一个 host 不同用户/端口是两笔账，不能互相覆盖。
    func testAccountKeysAreDistinct() {
        let a = SSHPasswordStore.account(for: target)
        let b = SSHPasswordStore.account(
            for: SSHTarget(host: "unit-test.invalid", port: 22, username: "other"))
        let c = SSHPasswordStore.account(
            for: SSHTarget(host: "unit-test.invalid", port: 2222, username: "cogniterm-unit-test"))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
        XCTAssertTrue(a.hasPrefix("ssh-password:"))
    }

    func testSaveReadRemoveRoundTrip() {
        SSHPasswordStore.removePassword(for: target)
        XCTAssertNil(SSHPasswordStore.password(for: target))
        XCTAssertFalse(SSHPasswordStore.hasPassword(for: target))

        XCTAssertTrue(SSHPasswordStore.save("s3cret-with-'quotes'", for: target),
                      "Keychain 写入失败（被锁或未签名进程？）")
        XCTAssertEqual(SSHPasswordStore.password(for: target), "s3cret-with-'quotes'")
        XCTAssertTrue(SSHPasswordStore.hasPassword(for: target))

        // 覆盖写：不该产生第二笔同账号的记录。
        XCTAssertTrue(SSHPasswordStore.save("rotated", for: target))
        XCTAssertEqual(SSHPasswordStore.password(for: target), "rotated")

        SSHPasswordStore.removePassword(for: target)
        XCTAssertNil(SSHPasswordStore.password(for: target))
    }

    /// 空密码不写入，也不该把已有的覆盖成空串。
    func testEmptyPasswordIsRejected() {
        XCTAssertTrue(SSHPasswordStore.save("real", for: target))
        XCTAssertFalse(SSHPasswordStore.save("", for: target))
        XCTAssertEqual(SSHPasswordStore.password(for: target), "real")
    }
}
