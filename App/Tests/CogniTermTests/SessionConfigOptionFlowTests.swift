import XCTest
@testable import CogniTerm
import AcpClient

/// 会话内切换模型的 App 侧链路。
///
/// 覆盖三件容易被"看起来能用"骗过去的事：
///   1. `session/new` 的 configOptions 真的落到了 UI 读的那个属性上；
///   2. 选择器的写入走的是 `session/set_config_option`，且以服务端返回的整份状态为准；
///   3. 失败不静默——不乐观更新、不假装成功，且把原因留在诊断与轨迹里。
///
/// 用内置 DemoPeer 驱动（与真实 dsh 同一套 ACP 线格式），不需要 runtime / API Key。
@MainActor
final class SessionConfigOptionFlowTests: XCTestCase {

    private let flashValue = "[\"deepseek-official\",\"deepseek-flash\"]"
    private let proValue = "[\"deepseek-official\",\"deepseek-v4-pro\"]"

    override func tearDown() async throws {
        await SidecarService.shared.stop()
    }

    func testDemoSessionAdvertisesModelAndSwitchesIt() async throws {
        let sidecar = SidecarService.shared
        let conversation = ConversationModel()
        sidecar.conversation = conversation
        await sidecar.stop()

        await sidecar.startDemo()
        XCTAssertEqual(sidecar.status, .ready)
        XCTAssertEqual(sidecar.sessionID, "demo-session-1")

        // 1. session/new 的选项集到达了 sidecar（UI 只读它）。
        let model = try XCTUnwrap(sidecar.modelConfigOption)
        XCTAssertEqual(model.id, SessionConfigID.model)
        XCTAssertEqual(model.currentSelectValue, flashValue)
        XCTAssertEqual(model.currentLabel, "deepseek-flash")
        XCTAssertEqual(model.selectOptions?.allOptions.count, 2)

        // 2. 切换 → 服务端返回的整份状态替换本地状态。
        await sidecar.setConfigOption(id: SessionConfigID.model, value: proValue)
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, proValue)
        XCTAssertEqual(sidecar.modelConfigOption?.currentLabel, "deepseek-v4-pro")
        XCTAssertEqual(sidecar.configOptions.count, 1, "整份替换，不是增删条目")

        // 成功后要有可见回执，否则用户无法确认到底切没切。
        XCTAssertTrue(conversation.rows.contains { $0.kind == .system && $0.text.contains("deepseek-v4-pro") },
                      "切换成功应写一行系统提示")
        XCTAssertFalse(sidecar.diagnostics.contains { $0.contains("[set_config_option]") })

        // 3. 选项集是会话态：断连即清空（留着会让人以为切了还在）。
        await sidecar.stop()
        XCTAssertTrue(sidecar.configOptions.isEmpty)
    }

    func testRejectedModelSwitchKeepsServerStateAndReportsIt() async throws {
        let sidecar = SidecarService.shared
        let conversation = ConversationModel()
        sidecar.conversation = conversation
        await sidecar.startDemo()

        await sidecar.setConfigOption(id: SessionConfigID.model,
                                      value: "[\"deepseek-official\",\"does-not-exist\"]")

        // fail-closed：值没被接受就保持原值，界面不会显示一个服务端并不认的模型。
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, flashValue)
        XCTAssertTrue(conversation.rows.contains { $0.kind == .system && $0.text.contains("失败") })
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("[set_config_option]") },
                      "失败必须留在诊断里，不能只弹一句就消失")
    }

    /// `config_option_update` 通知的归属与过滤（SidecarService 是唯一持有者）。
    func testConfigOptionUpdateIsAppliedAndFilteredBySession() async throws {
        let sidecar = SidecarService.shared
        sidecar.conversation = ConversationModel()
        await sidecar.startDemo()
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, flashValue)

        // 当前会话的广播 → 整体替换。
        sidecar.consume((method: AcpMethod.sessionUpdate,
                         params: Self.configOptionUpdate(sessionId: "demo-session-1", currentValue: proValue)))
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, proValue)

        // 别的会话的迟到广播 → 丢弃，不覆盖当前会话的状态。
        sidecar.consume((method: AcpMethod.sessionUpdate,
                         params: Self.configOptionUpdate(sessionId: "另一个会话", currentValue: flashValue)))
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, proValue)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("丢弃非当前会话") })

        // 载荷坏掉 → 保留上一份可用状态（不是"状态被重置"）。
        let broken = Data("""
        { "sessionId": "demo-session-1",
          "update": { "sessionUpdate": "config_option_update", "configOptions": "不是数组" } }
        """.utf8)
        sidecar.consume((method: AcpMethod.sessionUpdate, params: broken))
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, proValue)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("保留上一份选项集") })

        // 非 session/update 的通知不碰选项集。
        sidecar.consume((method: "别的/方法", params: broken))
        XCTAssertEqual(sidecar.modelConfigOption?.currentSelectValue, proValue)
    }

    /// 会话建立时若对端没返回 configOptions，要显式记诊断——"不支持"和"支持但列表为空"
    /// 在界面上长得一样（都是空白），只能靠诊断区分。
    func testMissingConfigOptionsIsRecordedNotSilent() async throws {
        let sidecar = SidecarService.shared
        sidecar.conversation = ConversationModel()
        await sidecar.startDemo()

        // 直接验 applyConfigOptions 的 nil 分支语义（session/new 未返回该字段的情形）。
        sidecar.applyConfigOptions(nil, reason: "session/new")

        XCTAssertTrue(sidecar.configOptions.isEmpty)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("未返回 configOptions") })
    }

    // MARK: - helpers

    /// 构造一条 `session/update` 通知的 **params 子对象**（信封由 AcpConnection 剥掉，
    /// `consume` 拿到的就是这一层）。
    private static func configOptionUpdate(sessionId: String, currentValue: String) -> Data {
        let params: [String: Any] = [
            "sessionId": sessionId,
            "update": [
                "sessionUpdate": "config_option_update",
                "configOptions": [[
                    "id": "model",
                    "name": "Model",
                    "category": "model",
                    "type": "select",
                    "currentValue": currentValue,
                    "options": [[
                        "group": "deepseek-official",
                        "name": "DeepSeek",
                        "options": [
                            ["value": currentValue, "name": "当前值"],
                        ],
                    ]],
                ]],
            ],
        ]
        // 测试夹具，结构恒定。
        // swiftlint:disable:next force_try
        return try! JSONSerialization.data(withJSONObject: params)
    }
}
