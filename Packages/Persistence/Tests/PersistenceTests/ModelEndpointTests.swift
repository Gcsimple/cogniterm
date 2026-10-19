import XCTest
@testable import Persistence

final class ModelEndpointTests: XCTestCase {

    // MARK: 路由名规范化

    func testRouteIDIsLowercasedAndHyphenated() {
        XCTAssertEqual(ModelEndpoint.normalizedRouteID("Local Qwen"), "local-qwen")
        XCTAssertEqual(ModelEndpoint.normalizedRouteID("local_qwen"), "local-qwen")
        XCTAssertEqual(ModelEndpoint.normalizedRouteID("  LAN--Qwen  "), "lan-qwen")
        XCTAssertEqual(ModelEndpoint.normalizedRouteID("qwen3.8"), "qwen3-8")
    }

    func testRouteIDNeverEmpty() {
        // 全非法字符时不能让 provider key 变成空串——那会让 patch 生成一段
        // `providers: { :` 的坏 YAML，dsh 启动直接失败。
        XCTAssertEqual(ModelEndpoint.normalizedRouteID(""), "provider")
        XCTAssertEqual(ModelEndpoint.normalizedRouteID("///"), "provider")
    }

    func testApiKeyEnvNameDerivesFromRouteID() {
        let endpoint = ModelEndpoint(id: "Local-Qwen", displayName: "本地", baseURL: "http://127.0.0.1:8000/v1")
        XCTAssertEqual(endpoint.apiKeyEnvName, "COGNITERM_KEY_LOCAL_QWEN")
    }

    // MARK: 可用性

    func testEndpointWithoutModelsIsUnusable() {
        let endpoint = ModelEndpoint(id: "a", displayName: "A", baseURL: "http://127.0.0.1:8000/v1")
        XCTAssertFalse(endpoint.isUsable, "没有模型的端点会让 pi-ai 拒绝整份配置")
    }

    func testEndpointWithNonHttpURLIsUnusable() {
        let endpoint = ModelEndpoint(id: "a", displayName: "A", baseURL: "127.0.0.1:8000",
                                     models: [ModelSpec(id: "m")])
        XCTAssertFalse(endpoint.isUsable)
    }

    func testDisabledEndpointIsUnusable() {
        let endpoint = ModelEndpoint(id: "a", displayName: "A", baseURL: "http://127.0.0.1:8000/v1",
                                     models: [ModelSpec(id: "m")], enabled: false)
        XCTAssertFalse(endpoint.isUsable)
    }

    func testTrailingSlashIsStripped() {
        let endpoint = ModelEndpoint(id: "a", displayName: "A", baseURL: " http://127.0.0.1:8000/v1// ",
                                     models: [ModelSpec(id: "m")])
        XCTAssertEqual(endpoint.normalizedBaseURL, "http://127.0.0.1:8000/v1")
    }

    // MARK: patch 渲染

    func testRenderReturnsNilWithoutUsableEndpoints() {
        XCTAssertNil(ProviderPatch.render(endpoints: []))
        XCTAssertNil(ProviderPatch.render(endpoints: [
            ModelEndpoint(id: "a", displayName: "A", baseURL: "http://127.0.0.1:8000/v1")
        ]))
    }

    func testRenderProducesPiAiRoutesAndAcpNeutralShape() {
        let endpoint = ModelEndpoint(
            id: "Local Qwen",
            displayName: "本地 Qwen3.8-27B",
            baseURL: "http://localhost:8000/v1/",
            models: [ModelSpec(id: "qwen3.8-27b", name: "Qwen3.8-27B", contextWindow: 262144)],
            timeoutMs: 300_000
        )
        let text = try! XCTUnwrap(ProviderPatch.render(endpoints: [endpoint]))

        // 挂载点必须是 llm-pi-ai，且 provider key 用规范化后的路由名
        XCTAssertTrue(text.contains("- id: llm-pi-ai"))
        XCTAssertTrue(text.contains("\n      local-qwen:\n"))
        XCTAssertTrue(text.contains("api: openai-completions"))
        XCTAssertTrue(text.contains("baseURL: 'http://localhost:8000/v1'"), "末尾斜杠必须去掉")
        XCTAssertTrue(text.contains("timeoutMs: 300000"))
        XCTAssertTrue(text.contains("- id: 'qwen3.8-27b'"))
        XCTAssertTrue(text.contains("contextWindow: 262144"))
        // apiKeyEnv **始终**要写：pi-ai 对 openai-completions 路由无条件要求凭据，
        // 变量缺失时每次请求都失败 `PI_AI_ERROR: No API key for provider: <route>`
        // ——即使上游是根本不校验 Authorization 的本地 vLLM（2026-10-19 headless 实证）。
        // 无 Keychain 记录时由 App 侧注入占位值，所以 patch 里必须有这个引用。
        XCTAssertTrue(text.contains("apiKeyEnv: COGNITERM_KEY_LOCAL_QWEN"))
    }

    func testRenderDerivesApiKeyEnvFromRouteNotFromKeychainAccount() {
        // 变量的名字永远由路由名派生，与用户在 Keychain 里起的 account 名无关
        // ——两边不一致的话 App 注入的变量和 patch 里的引用就不是同一个名字。
        let endpoint = ModelEndpoint(
            id: "gw", displayName: "网关", baseURL: "https://gw.example/v1",
            models: [ModelSpec(id: "m")], apiKeyAccount: "provider-key-gw"
        )
        let text = try! XCTUnwrap(ProviderPatch.render(endpoints: [endpoint]))
        XCTAssertTrue(text.contains("apiKeyEnv: COGNITERM_KEY_GW"))
    }

    func testRenderQuotesColonBearingModelID() {
        // 裸标量 `qwen3:27b` 会被 YAML 解析成 mapping，dsh 直接起不来
        let endpoint = ModelEndpoint(id: "e", displayName: "E", baseURL: "http://h:1/v1",
                                     models: [ModelSpec(id: "qwen3:27b")])
        let text = try! XCTUnwrap(ProviderPatch.render(endpoints: [endpoint]))
        XCTAssertTrue(text.contains("- id: 'qwen3:27b'"))
    }

    func testRenderSkipsUnusableEndpointsButKeepsOthers() {
        let good = ModelEndpoint(id: "good", displayName: "Good", baseURL: "http://h:1/v1",
                                 models: [ModelSpec(id: "m")])
        let bad = ModelEndpoint(id: "bad", displayName: "Bad", baseURL: "")
        let text = try! XCTUnwrap(ProviderPatch.render(endpoints: [bad, good]))
        XCTAssertTrue(text.contains("good:"))
        XCTAssertFalse(text.contains("bad:"))
    }

    func testRenderEscapesSingleQuotesInDisplayName() {
        let endpoint = ModelEndpoint(id: "e", displayName: "Bob's GPU", baseURL: "http://h:1/v1",
                                     models: [ModelSpec(id: "m")])
        let text = try! XCTUnwrap(ProviderPatch.render(endpoints: [endpoint]))
        XCTAssertTrue(text.contains("displayName: 'Bob''s GPU'"))
    }

    // MARK: 存储

    func testStoreRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cogniterm-endpoints-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ModelEndpointStore(endpoints: [
            ModelEndpoint(id: "local", displayName: "本地", baseURL: "http://127.0.0.1:8000/v1",
                          models: [ModelSpec(id: "m", contextWindow: 8192)], timeoutMs: 60_000)
        ])
        try store.save(to: url)
        XCTAssertEqual(ModelEndpointStore.load(from: url), store)
    }

    func testCorruptFileFallsBackToEmptyStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cogniterm-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)

        // fail-soft：坏配置只让自定义端点消失，不能让 App 起不来
        XCTAssertTrue(ModelEndpointStore.load(from: url).endpoints.isEmpty)
    }

    // MARK: 默认模型 = (provider, model)

    func testSelectionIDSplitsEvenWhenModelHasSeparators() {
        // 模型 id 里常带 `/`（org/model）和 `:`（qwen3:27b）；tag 必须能原样还原，
        // 否则设置页选中本地模型后存进去的是半截 id，会话起不来。
        let selection = DefaultModelSelection(providerID: "local-qwen", modelID: "org/qwen3:27b")
        XCTAssertEqual(DefaultModelSelection.split(selection.selectionID), selection)
    }

    func testSelectionIDRejectsMalformedInput() {
        XCTAssertNil(DefaultModelSelection.split("local-qwen"))
        XCTAssertNil(DefaultModelSelection.split("\u{1F}model"))
        XCTAssertNil(DefaultModelSelection.split("provider\u{1F}"))
        XCTAssertNil(DefaultModelSelection.split("a\u{1F}b\u{1F}c"))
    }

    func testSettingsDefaultProviderIsBuiltinDeepSeek() {
        // 旧库没有 providerRaw 这个字段。缺失时必须回到内置 DeepSeek——
        // 这正是加这个字段之前的行为，不能让历史用户升级后默认 provider 变成空串。
        let settings = AppSettings()
        XCTAssertEqual(settings.providerID, DefaultModelSelection.deepSeekProvider)

        settings.providerRaw = nil
        XCTAssertEqual(settings.providerID, DefaultModelSelection.deepSeekProvider)

        settings.providerRaw = "   "
        XCTAssertEqual(settings.providerID, DefaultModelSelection.deepSeekProvider)

        settings.providerRaw = "local-qwen"
        XCTAssertEqual(settings.providerID, "local-qwen")
    }

    func testSettingsModelSelectionRoundTripKeepsCustomIDs() {
        // agentModel 枚举只有两档，自定义端点的 id 必须原样保留在 modelRaw 里。
        let settings = AppSettings()
        settings.modelSelection = DefaultModelSelection(providerID: "local-qwen", modelID: "Qwen3.8-27B")

        XCTAssertEqual(settings.modelID, "Qwen3.8-27B")
        XCTAssertEqual(settings.modelRaw, "Qwen3.8-27B")
        XCTAssertEqual(settings.providerRaw, "local-qwen")
        XCTAssertEqual(settings.modelSelection,
                       DefaultModelSelection(providerID: "local-qwen", modelID: "Qwen3.8-27B"))
        // 枚举读取对目录外 id 回落 flash 是既有契约（fail-soft），这里只是确认它没变。
        XCTAssertEqual(settings.agentModel, .flash)
    }
}
