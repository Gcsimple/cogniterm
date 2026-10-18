import XCTest
@testable import AcpClient

/// `configOptions` 一族的线格式回归。
///
/// 夹具全部是**字面量 JSON**，照 dsh 0.2 的实际输出抄写，不经我们自己的编码器。
/// 理由：用自家类型造夹具只能证明类型自洽，证明不了它读得懂 dsh——
/// 而这一族字段最容易出的错恰恰是"类型定义得挺好看，但线上形状对不上"。
final class SessionConfigOptionTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.acp.decode(type, from: Data(json.utf8))
    }

    // MARK: - session/new

    /// dsh 的 model option：分组数组 + currentValue 是 `["provider","model"]` 的 JSON 串。
    func testDecodesGroupedModelOptionFromSessionNew() throws {
        let json = """
        {
          "sessionId": "sess-1",
          "configOptions": [
            {
              "id": "model",
              "name": "Model",
              "category": "model",
              "type": "select",
              "currentValue": "[\\"deepseek-official\\",\\"deepseek-flash\\"]",
              "options": [
                {
                  "group": "deepseek-official",
                  "name": "DeepSeek",
                  "options": [
                    { "value": "[\\"deepseek-official\\",\\"deepseek-flash\\"]",
                      "name": "DeepSeek-V4.1-Flash" },
                    { "value": "[\\"deepseek-official\\",\\"deepseek-v4-pro\\"]",
                      "name": "DeepSeek-V4-Pro",
                      "description": "更强的 agentic 编码与困难推理" }
                  ]
                }
              ]
            }
          ]
        }
        """
        let result = try decode(SessionNewResult.self, json)
        XCTAssertEqual(result.sessionId, "sess-1")
        XCTAssertNil(result.modes, "dsh 0.2 的 session/new 不返回 modes")

        let options = try XCTUnwrap(result.configOptions)
        XCTAssertEqual(options.count, 1)
        let model = try XCTUnwrap(options.first)
        XCTAssertEqual(model.id, SessionConfigID.model)
        XCTAssertEqual(model.name, "Model")
        XCTAssertEqual(model.category, "model")
        XCTAssertTrue(model.isSelect)
        XCTAssertEqual(model.currentSelectValue, "[\"deepseek-official\",\"deepseek-flash\"]")

        let selectOptions = try XCTUnwrap(model.selectOptions)
        guard case .grouped(let groups) = selectOptions else {
            return XCTFail("带 group 键的选项集应判为 grouped")
        }
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].group, "deepseek-official")
        XCTAssertEqual(groups[0].label, "DeepSeek")
        XCTAssertEqual(selectOptions.allOptions.count, 2)

        let pro = try XCTUnwrap(selectOptions.option(forValue: "[\"deepseek-official\",\"deepseek-v4-pro\"]"))
        XCTAssertEqual(pro.label, "DeepSeek-V4-Pro")
        XCTAssertEqual(pro.description, "更强的 agentic 编码与困难推理")
        // currentValue 在选项集里能查到 → 展示名取选项名，而不是裸 JSON 串。
        XCTAssertEqual(model.currentLabel, "DeepSeek-V4.1-Flash")
    }

    /// dsh 为**目录外**的 currentValue 合成的选项：`name` 等于 `value` 本身。
    ///
    /// 这不是臆造的边界情况，是真实线格式：`AcpModelControl.state()` 在
    /// `!choices.has(currentValue)` 时把当前值 unshift 进分组，name 直接取 model id。
    /// 2026-10-16 就因为默认模型绑了目录外的别名（`deepseek-v4-flash`），
    /// 会话选择器里出现了两条其实是同一个模型的条目。
    func testDecodesSynthesizedEntryForValueOutsideCatalog() throws {
        let alias = "[\"deepseek-official\",\"deepseek-v4-flash\"]"
        let json = """
        {
          "configOptions": [
            { "id": "model", "name": "Model", "category": "model", "type": "select",
              "currentValue": "[\\"deepseek-official\\",\\"deepseek-v4-flash\\"]",
              "options": [
                { "group": "deepseek-official", "name": "DeepSeek", "options": [
                  { "value": "[\\"deepseek-official\\",\\"deepseek-v4-flash\\"]",
                    "name": "deepseek-v4-flash" },
                  { "value": "[\\"deepseek-official\\",\\"deepseek-flash\\"]",
                    "name": "DeepSeek-V4.1-Flash" }
                ] }
              ] }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        let model = try XCTUnwrap(result.option(id: SessionConfigID.model))
        XCTAssertEqual(model.currentSelectValue, alias)
        XCTAssertEqual(model.currentLabel, "deepseek-v4-flash",
                       "合成项的展示名就是 id 本身（与目录项 DeepSeek-V4.1-Flash 不同名）")
        XCTAssertEqual(model.selectOptions?.allOptions.count, 2,
                       "合成项与目录项同时出现在同一个分组里")
    }

    /// Ungrouped 形状（同一 anyOf 的另一支）：扁平数组，无 group 键。
    func testDecodesUngroupedOptions() throws {
        let json = """
        {
          "configOptions": [
            {
              "id": "reasoning_effort",
              "name": "Reasoning effort",
              "category": "thought_level",
              "type": "select",
              "currentValue": "",
              "options": [
                { "value": "", "name": "Provider default" },
                { "value": "low", "name": "Low" },
                { "value": "high", "name": "High" }
              ]
            }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        let option = try XCTUnwrap(result.option(id: SessionConfigID.reasoningEffort))
        let options = try XCTUnwrap(option.selectOptions)
        guard case .ungrouped(let flat) = options else {
            return XCTFail("无 group 键的选项集应判为 ungrouped")
        }
        XCTAssertEqual(flat.count, 3)
        // 统一视图把 ungrouped 包成一个匿名组，展示逻辑只写一遍。
        XCTAssertEqual(options.groups.count, 1)
        XCTAssertNil(options.groups[0].group)
        XCTAssertEqual(option.currentSelectValue, "")
        XCTAssertEqual(option.currentLabel, "Provider default",
                       "空串 currentValue 应经选项集查到可读标签")
        XCTAssertEqual(result.option(category: "thought_level")?.id, SessionConfigID.reasoningEffort)
    }

    /// boolean 变体（schema 的另一分支；dsh 目前不产出，但要读得懂、不炸）。
    func testDecodesBooleanOption() throws {
        let json = """
        {
          "configOptions": [
            { "id": "auto_approve", "name": "Auto approve", "type": "boolean", "currentValue": true }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        let option = try XCTUnwrap(result.configOptions.first)
        XCTAssertFalse(option.isSelect)
        XCTAssertNil(option.selectOptions)
        XCTAssertEqual(option.kind, .boolean(currentValue: true))
        XCTAssertEqual(option.currentLabel, "开")
    }

    /// 未知 type：ACP 允许扩展，必须保留 id/name/category 而不是把整条丢掉。
    func testKeepsUnknownOptionType() throws {
        let json = """
        {
          "configOptions": [
            { "id": "_vendor_thing", "name": "Vendor", "category": "other",
              "type": "future_shape", "currentValue": "x" }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        let option = try XCTUnwrap(result.configOptions.first)
        XCTAssertEqual(option.kind, .unknown(type: "future_shape"))
        XCTAssertEqual(option.id, "_vendor_thing")
        XCTAssertEqual(option.label, "Vendor")
    }

    /// 坏项跳过、好项保留（schema 的 `x-deserialize-skip-invalid-items`）。
    ///
    /// 这条是**回归点**：如果解码遇到坏项就整数组失败，UI 会静默失去模型选择器——
    /// 而"文件/字段存在性"类的检查一个都发现不了。
    func testSkipsMalformedItemsAndKeepsSiblings() throws {
        let json = """
        {
          "configOptions": [
            { "id": "model", "name": "Model", "type": "select",
              "currentValue": "m1",
              "options": [
                { "group": "deepseek-official", "name": "DeepSeek",
                  "options": [
                    { "value": "m1", "name": "One" },
                    { "value": 12345, "name": "坏项：value 不是字符串" }
                  ] }
              ] },
            { "name": "没有 id 的项" },
            { "id": "reasoning_effort", "name": "Effort", "type": "select",
              "currentValue": "low",
              "options": [ { "value": "low", "name": "Low" }, { "no_value": true } ] }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        XCTAssertEqual(result.configOptions.map(\.id),
                       [SessionConfigID.model, SessionConfigID.reasoningEffort],
                       "缺 id 的项应被丢弃，其余两个保留")
        // 组内的坏项也要只丢自己：组与组内的好项都得在。
        let model = try XCTUnwrap(result.option(id: SessionConfigID.model))
        XCTAssertEqual(model.selectOptions?.allOptions.map(\.label), ["One"])
        let effort = try XCTUnwrap(result.option(id: SessionConfigID.reasoningEffort))
        XCTAssertEqual(effort.selectOptions?.allOptions.map(\.label), ["Low"])
    }

    /// 字段类型不符（`name` 是数字、`options` 是对象）不能抛错。
    func testToleratesWrongTypedFields() throws {
        let json = """
        {
          "configOptions": [
            { "id": "model", "name": 42, "type": "select", "currentValue": "m1",
              "options": { "not": "an array" } }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        let option = try XCTUnwrap(result.configOptions.first)
        XCTAssertNil(option.name)
        XCTAssertEqual(option.label, "model", "缺 name 时回落 id")
        XCTAssertEqual(option.selectOptions?.allOptions.count, 0)
    }

    /// 响应体里没有 configOptions（对端未实现）与空数组是两件事。
    func testDistinguishesMissingFromEmptyConfigOptions() throws {
        let missing = try decode(SessionConfigOptionsResult.self, "{}")
        XCTAssertTrue(missing.configOptions.isEmpty)

        let newSession = try decode(SessionNewResult.self, #"{ "sessionId": "s" }"#)
        XCTAssertNil(newSession.configOptions, "键不存在必须是 nil，而不是被规范化成空数组")

        let empty = try decode(SessionNewResult.self, #"{ "sessionId": "s", "configOptions": [] }"#)
        XCTAssertEqual(empty.configOptions?.count, 0)
    }

    // MARK: - set_config_option 请求

    /// `value_id` 变体：wire 上**不能出现 `type` 字段**（缺省即该变体）。
    func testSetParamsEncodesValueIDVariantWithoutType() throws {
        let params = SetSessionConfigOptionParams(sessionId: "s1",
                                                  configId: SessionConfigID.model,
                                                  value: "[\"deepseek-official\",\"deepseek-v4-pro\"]")
        let data = try JSONEncoder.acp.encode(params)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"configId":"model","sessionId":"s1","value":"[\"deepseek-official\",\"deepseek-v4-pro\"]"}"#)

        let roundTripped = try JSONDecoder.acp.decode(SetSessionConfigOptionParams.self, from: data)
        XCTAssertEqual(roundTripped, params)
    }

    /// boolean 变体：`type: "boolean"` 与布尔 value 必须同时出现（schema required 两个键）。
    func testSetParamsEncodesBooleanVariant() throws {
        let params = SetSessionConfigOptionParams(sessionId: "s1",
                                                  configId: "auto_approve",
                                                  value: .boolean(false))
        let data = try JSONEncoder.acp.encode(params)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"{"configId":"auto_approve","sessionId":"s1","type":"boolean","value":false}"#)
        XCTAssertEqual(try JSONDecoder.acp.decode(SetSessionConfigOptionParams.self, from: data), params)
    }

    /// schema 明写：type 缺失时默认走 value_id 变体；未知 type 若载荷是字符串也归入该变体。
    func testSetParamsFallsBackToValueIDForUnknownType() throws {
        let json = #"{ "sessionId": "s", "configId": "c", "type": "weird", "value": "v" }"#
        let params = try decode(SetSessionConfigOptionParams.self, json)
        XCTAssertEqual(params.value, .id("v"))
    }

    // MARK: - config_option_update 通知

    /// 夹具是 `session/update` 通知的 **params 子对象**（信封由 AcpConnection 剥掉，
    /// `notifications` 流交给上层的就是这一层）。
    func testDecodesConfigOptionUpdateNotification() throws {
        let json = """
        {
          "sessionId": "sess-1",
          "update": {
            "sessionUpdate": "config_option_update",
            "configOptions": [
              { "id": "model", "name": "Model", "category": "model", "type": "select",
                "currentValue": "m2",
                "options": [ { "group": "g", "name": "G", "options": [ { "value": "m2", "name": "Two" } ] } ] }
            ]
          }
        }
        """
        let params = try decode(SessionNotificationParams.self, json)
        XCTAssertEqual(params.sessionId, "sess-1")
        let update = try XCTUnwrap(params.update)
        XCTAssertEqual(update.sessionUpdate, SessionUpdateEvent.Kind.configOptionUpdate)
        let options = try XCTUnwrap(update.sessionConfigOptions)
        XCTAssertEqual(options.count, 1)
        XCTAssertEqual(options[0].currentSelectValue, "m2")
        XCTAssertEqual(options[0].currentLabel, "Two")
    }

    /// 载荷坏掉时**只丢选项集，不能丢整条通知**。
    ///
    /// `config_option_update` 与 `agent_message_chunk` 共用同一个 `session/update`
    /// 信封；若把 configOptions 写进强类型字段，一次解码失败就会把该条通知整体变成
    /// "解不出来"——正文可能就这样被吞掉。所以它按 JSONValue 收。
    func testMalformedConfigOptionsDoNotKillTheNotification() throws {
        let json = """
        {
          "sessionId": "sess-1",
          "update": {
            "sessionUpdate": "config_option_update",
            "configOptions": "这不是数组"
          }
        }
        """
        let params = try decode(SessionNotificationParams.self, json)
        let update = try XCTUnwrap(params.update, "坏载荷不得让整条通知解不出来")
        XCTAssertEqual(update.sessionUpdate, SessionUpdateEvent.Kind.configOptionUpdate)
        XCTAssertEqual(update.configOptions?.stringValue, "这不是数组")
        XCTAssertNil(update.sessionConfigOptions, "非数组载荷 → nil，而不是空数组")
    }

    /// 同结构下的普通消息不受新字段影响（防止新增字段把老事件解码搞坏）。
    func testAgentMessageChunkStillDecodes() throws {
        let json = """
        {
          "sessionId": "sess-1",
          "update": {
            "sessionUpdate": "agent_message_chunk",
            "messageId": "m1",
            "content": { "type": "text", "text": "你好" }
          }
        }
        """
        let params = try decode(SessionNotificationParams.self, json)
        let update = try XCTUnwrap(params.update)
        XCTAssertEqual(update.textContent, "你好")
        XCTAssertNil(update.sessionConfigOptions)
    }

    // MARK: - 响应体形状

    /// `session/set_config_option` 与 `session/resume` 是同一种回答：整份选项集。
    func testSetConfigOptionResponseCarriesFullOptionSet() throws {
        let json = """
        {
          "configOptions": [
            { "id": "model", "name": "Model", "category": "model", "type": "select",
              "currentValue": "m2",
              "options": [ { "group": "g", "name": "G",
                             "options": [ { "value": "m1", "name": "One" }, { "value": "m2", "name": "Two" } ] } ] }
          ]
        }
        """
        let result = try decode(SessionConfigOptionsResult.self, json)
        XCTAssertEqual(result.configOptions.count, 1)
        XCTAssertEqual(result.option(id: SessionConfigID.model)?.currentLabel, "Two")
    }
}
