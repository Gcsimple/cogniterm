import SwiftUI
import Persistence

// MARK: - 设置页里的端点清单

/// 「设置 → 模型端点」区块：管理本地部署 / 内网网关这类 OpenAI 兼容端点。
///
/// 为什么模型清单不在这里直接列进选择器：
/// 端点一旦挂上（`llm-pi-ai` 注册出路由），dsh 的 ACP 模型选项会**按 provider 分组
/// 列出全部模型**，会话内的模型选择器自动就有它们。这里只负责「端点存在与否」，
/// 不重复实现一份选择器。
struct ModelEndpointsSection: View {
    @ObservedObject var sidecar: SidecarService
    /// 端点清单变化后通知外层（设置页要用它刷新「默认模型」选择器的候选）。
    var onChange: () -> Void = {}

    @State private var store = ModelEndpointStore.load()
    @State private var editorTarget: EditorTarget?
    @State private var message: String?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let endpoint: ModelEndpoint
        let isNew: Bool
    }

    var body: some View {
        Section {
            if store.endpoints.isEmpty {
                Text("还没有自定义端点。添加后重连一次 sidecar，会话的模型选择器里就会多出这一组模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(store.endpoints) { endpoint in
                row(endpoint)
            }

            HStack {
                Button("添加端点…") {
                    editorTarget = EditorTarget(
                        endpoint: ModelEndpoint(id: "", displayName: "", baseURL: ""),
                        isNew: true
                    )
                }
                Spacer()
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("模型端点（本地部署 / 自定义网关）")
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("支持任意 OpenAI 兼容端点（vLLM / SGLang / 内网网关）。端点改动需重连 sidecar；已经挂上的模型在会话内可直接切换，不必重启。")
                Text(ModelEndpointStore.defaultFileURL().path)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .sheet(item: $editorTarget) { target in
            EndpointEditorView(endpoint: target.endpoint, isNew: target.isNew) { saved, plainKey in
                upsert(saved, plainKey: plainKey)
            }
        }
    }

    @ViewBuilder
    private func row(_ endpoint: ModelEndpoint) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { endpoint.enabled },
                set: { value in
                    var copy = endpoint
                    copy.enabled = value
                    upsert(copy, plainKey: nil)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 2) {
                Text(endpoint.displayName.isEmpty ? endpoint.id : endpoint.displayName)
                Text("\(endpoint.normalizedBaseURL) · \(endpoint.models.count) 个模型 · route \(ModelEndpoint.normalizedRouteID(endpoint.id))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 不可用的端点会被 ProviderPatch 静默跳过（patch 里根本不出现），
                // 用户只会看到「模型选择器里没有这一组」却查不出原因——把判据显式说出来。
                if let reason = unusableReason(endpoint) {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            Button("编辑") {
                editorTarget = EditorTarget(endpoint: endpoint, isNew: false)
            }
            .controlSize(.small)

            Button {
                remove(endpoint)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// 端点为什么不会被挂载；可用时返回 nil。
    ///
    /// `isUsable` 是 fail-closed 的：只要有一条不满足，patch 里就一个字节都不写。
    /// 这里把同一条判据翻译成用户能看懂的话，避免「看起来配好了但没生效」。
    private func unusableReason(_ endpoint: ModelEndpoint) -> String? {
        if !endpoint.enabled { return "已停用，不会挂载" }
        let url = endpoint.normalizedBaseURL
        if url.isEmpty { return "未填 Base URL，不会挂载" }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https", parsed.host?.isEmpty == false else {
            return "Base URL 需要 http:// 或 https:// 开头并带主机名，当前不会挂载"
        }
        if endpoint.models.allSatisfy({ $0.id.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "模型列表为空，不会挂载"
        }
        return nil
    }

    private func upsert(_ endpoint: ModelEndpoint, plainKey: String?) {
        var copy = endpoint
        copy.id = ModelEndpoint.normalizedRouteID(copy.id)

        // 路由名是 pi-ai 的 provider key，重名会让 patch 里出现两个同名 key（后者覆盖前者），
        // 静默丢掉一个端点。这里直接拒绝并提示，而不是悄悄改名。
        if store.endpoints.contains(where: { $0.id != endpoint.id && $0.id == copy.id }) {
            message = "路由名 \(copy.id) 已被占用"
            return
        }

        if let plainKey {
            let account = "provider-key-\(copy.id)"
            if plainKey.isEmpty {
                KeychainService(account: account).clear()
                copy.apiKeyAccount = nil
            } else {
                do {
                    try KeychainService(account: account).save(plainKey)
                    copy.apiKeyAccount = account
                } catch {
                    message = "Key 保存失败：\(error)"
                    return
                }
            }
        }

        if let index = store.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            store.endpoints[index] = copy
        } else {
            store.endpoints.append(copy)
        }
        persist()
    }

    private func remove(_ endpoint: ModelEndpoint) {
        store.endpoints.removeAll { $0.id == endpoint.id }
        KeychainService(account: "provider-key-\(endpoint.id)").clear()
        persist()
    }

    private func persist() {
        do {
            try store.save()
            onChange()
            let blocked = store.endpoints.filter { unusableReason($0) != nil }.count
            message = blocked == 0
                ? "已保存，重连后生效"
                : "已保存；\(blocked) 个端点未满足挂载条件（见橙色提示）"
        } catch {
            message = "保存失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 端点编辑

struct EndpointEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let isNew: Bool
    let onSave: (ModelEndpoint, String?) -> Void

    @State private var draft: ModelEndpoint
    @State private var apiKey: String
    @State private var modelsText: String
    @State private var contextWindowText: String
    @State private var timeoutText: String
    @State private var status: String?
    @State private var fetching = false

    init(endpoint: ModelEndpoint,
         isNew: Bool,
         onSave: @escaping (ModelEndpoint, String?) -> Void) {
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: endpoint)
        _modelsText = State(initialValue: endpoint.models.map(\.id).joined(separator: "\n"))
        let window = endpoint.models.compactMap(\.contextWindow).first ?? 262_144
        _contextWindowText = State(initialValue: String(window))
        _timeoutText = State(initialValue: String(endpoint.timeoutMs ?? 300_000))
        // 已存过的 key 不回填明文（Keychain 里读得到，但没必要把密钥铺在输入框里）；
        // 留空表示「不改动」，输入内容则覆盖。
        _apiKey = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "添加模型端点" : "编辑模型端点")
                .font(.headline)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField("显示名", text: $draft.displayName, prompt: Text("本地 Qwen3.8-27B"))
                    TextField("路由名", text: $draft.id, prompt: Text("local-qwen"))
                    Text("路由名会出现在模型选择器的分组标题里，只能用小写字母、数字和连字符。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("连接") {
                    TextField("Base URL", text: $draft.baseURL, prompt: Text("http://10.100.51.218:18506/v1"))
                    SecureField("API Key（本地无鉴权可留空）", text: $apiKey,
                                prompt: Text(draft.apiKeyAccount == nil ? "未设置" : "已保存在 Keychain，留空不修改"))
                    TextField("超时（毫秒）", text: $timeoutText)
                    Text("本地推理常几十秒才出首 token；300000 = 5 分钟。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section("模型") {
                    HStack {
                        Button(fetching ? "拉取中…" : "从端点拉取模型列表") {
                            Task { await fetchModels() }
                        }
                        .disabled(fetching || draft.normalizedBaseURL.isEmpty)
                        Spacer()
                        TextField("上下文窗口", text: $contextWindowText)
                            .frame(width: 110)
                    }
                    TextEditor(text: $modelsText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 84)
                    Text("每行一个模型 id。上下文窗口会应用到全部模型——填大了服务端直接 400，填小了会提前压缩历史。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.baseURL.isEmpty || draft.displayName.isEmpty)
            }
            .padding(.top, 12)
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    private func fetchModels() async {
        fetching = true
        defer { fetching = false }
        do {
            let ids = try await ModelDiscovery.listModels(
                baseURL: draft.normalizedBaseURL,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            if ids.isEmpty {
                status = "端点没有返回任何模型（检查 baseURL 是否带 /v1）"
            } else {
                modelsText = ids.joined(separator: "\n")
                status = "拉到 \(ids.count) 个模型；填好上下文窗口后保存"
            }
        } catch {
            status = "拉取失败：\(error.localizedDescription)"
        }
    }

    private func save() {
        var endpoint = draft
        endpoint.id = ModelEndpoint.normalizedRouteID(endpoint.id.isEmpty ? endpoint.displayName : endpoint.id)
        let window = Int(contextWindowText.trimmingCharacters(in: .whitespaces))
        let timeout = Int(timeoutText.trimmingCharacters(in: .whitespaces))

        endpoint.models = modelsText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ModelSpec(id: $0, name: nil, contextWindow: window) }
        endpoint.timeoutMs = (timeout ?? 0) > 0 ? timeout : nil
        endpoint.enabled = true

        // nil 表示「key 未改动」，交给上层沿用原 apiKeyAccount。
        onSave(endpoint, isNew || !apiKey.isEmpty ? apiKey : nil)
        dismiss()
    }
}

// MARK: - 模型发现

/// 从 OpenAI 兼容端点拉模型列表。
///
/// 这是 App 进程自己发的请求（不经 sidecar 沙箱），所以内网地址也能直连。
/// 只读 `data[].id`；不回写任何东西——采用与否由用户在编辑框里决定。
enum ModelDiscovery {
    struct Error: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct Response: Decodable {
        struct Item: Decodable { let id: String }
        let data: [Item]?
    }

    static func listModels(baseURL: String, apiKey: String?) async throws -> [String] {
        guard let url = URL(string: baseURL + "/models") else {
            throw Error(message: "Base URL 不合法")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error(message: "没有拿到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error(message: "HTTP \(http.statusCode)：\(Self.snippet(data))")
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw Error(message: "响应不是 OpenAI 的 /models 格式：\(Self.snippet(data))")
        }
        return (decoded.data ?? []).map(\.id).sorted()
    }

    private static func snippet(_ data: Data) -> String {
        String(decoding: data.prefix(160), as: UTF8.self)
    }
}
