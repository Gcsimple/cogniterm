import Foundation
import AcpClient

/// 内存脚本化 ACP 对端：在没有真实 dsh runtime / API Key 时，
/// 用它驱动完整的握手→会话→流式更新→反向审批交互。
///
/// 线格式对齐 dsh 0.2.0-rc.2 实证（App/Resources/runtime/node_modules/@deepseek-ai/dsh-acp/lib/index.js）：
/// - tool_call：title=工具名（"bash"），命令在 rawInput.command
/// - tool_call_update：status + content 数组（ToolCallContent）
/// - request_permission：toolCall 只带 toolCallId，命令需由客户端自行关联
/// - usage_update：used/size
final class DemoPeer {
    private let transport: LoopbackTransport
    private let sessionID = "demo-session-1"
    private var prompts = 0

    init(transport: LoopbackTransport) {
        self.transport = transport
        transport.responder = { [weak self] frame in
            self?.respond(frame) ?? []
        }
    }

    // MARK: - 帧构造

    private func dictionary(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func frame(_ object: [String: Any]) -> Data {
        // 演示夹具，结构恒定。
        // swiftlint:disable:next force_try
        try! JSONSerialization.data(withJSONObject: object)
    }

    private func success(id: Any?, result: [String: Any]) -> Data {
        frame(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func notification(_ method: String, params: [String: Any]) -> Data {
        frame(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func serverRequest(id: String, method: String, params: [String: Any]) -> Data {
        frame(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    /// dsh 0.2 真实线格式：params.update 即扁平事件，带 sessionUpdate 鉴别符。
    private func sessionEvent(_ event: [String: Any]) -> Data {
        notification(AcpMethod.sessionUpdate, params: [
            "sessionId": sessionID,
            "update": event,
        ])
    }

    private func agentMessage(id: String, text: String) -> Data {
        sessionEvent([
            "sessionUpdate": "agent_message_chunk",
            "messageId": id,
            "content": ["type": "text", "text": text],
        ])
    }

    /// dsh 0.2 实证：title 是工具名，命令文本在 rawInput.command。
    private func toolCallEvent(toolCallId: String, command: String) -> Data {
        sessionEvent([
            "sessionUpdate": "tool_call",
            "toolCallId": toolCallId,
            "title": "bash",
            "kind": "other",
            "status": "in_progress",
            "rawInput": ["command": command, "description": "演示工具调用"],
        ])
    }

    private func toolCallUpdateEvent(toolCallId: String, status: String, result: String) -> Data {
        sessionEvent([
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCallId,
            "status": status,
            "content": [["type": "content", "content": ["type": "text", "text": result]]],
        ])
    }

    private func usageEvent(used: Int, size: Int) -> Data {
        sessionEvent(["sessionUpdate": "usage_update", "used": used, "size": size])
    }

    private func planEvent() -> Data {
        sessionEvent([
            "sessionUpdate": "plan",
            "entries": [
                ["content": "检查工作区状态", "status": "completed", "priority": "high"],
                ["content": "给出后续建议", "status": "in_progress", "priority": "medium"],
            ],
        ])
    }

    /// dsh 0.2 实证：审批请求只携带 toolCallId。
    private var permissionRequestFrame: Data {
        serverRequest(id: "demo-perm-1", method: AcpMethod.requestPermission, params: [
            "sessionId": sessionID,
            "toolCall": ["toolCallId": "tc-1"],
            "options": [
                ["optionId": "allow-once", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "reject-once", "name": "拒绝", "kind": "reject_once"],
            ],
        ])
    }

    // MARK: - 会话配置项（对齐 dsh AcpModelControl 的实际输出形状）

    /// 演示里可选的两档模型；value 是 `modelValue(provider, model)` 的输出，
    /// 即 `JSON.stringify([provider, model])` 的字符串。拼错不会本地报错，
    /// 会一路发到服务端（dsh-llm-deepseek 对目录外 id 原样透传）。
    /// id 取 dsh 目录里的规范值，与 `Persistence.AgentModel` 保持一致。
    private let demoModels = ["deepseek-flash", "deepseek-v4-pro"]
    private var selectedModel = "deepseek-flash"

    private func modelValue(_ model: String) -> String {
        // 固定 provider，字符串形状与 dsh 完全一致。
        "[\"deepseek-official\",\"\(model)\"]"
    }

    /// 形状对齐：选项集是**分组数组**（键为 group），模型项 category=model。
    private func configOptions() -> [[String: Any]] {
        [[
            "id": "model",
            "name": "Model",
            "category": "model",
            "type": "select",
            "currentValue": modelValue(selectedModel),
            "options": [[
                "group": "deepseek-official",
                "name": "DeepSeek",
                "options": demoModels.map { ["value": modelValue($0), "name": $0] },
            ]],
        ]]
    }

    private var configOptionUpdateFrame: Data {
        sessionEvent(["sessionUpdate": "config_option_update",
                      "configOptions": configOptions()])
    }

    // MARK: - 对端逻辑

    private func respond(_ input: Data) -> [Data] {
        guard let request = dictionary(input) else { return [] }
        let method = request["method"] as? String

        // 客户端对 demo-perm-1 的应答（无 method 字段）：据此收尾一轮。
        if method == nil, let id = request["id"] as? String, id == "demo-perm-1" {
            let nested = (request["result"] as? [String: Any])?["outcome"] as? [String: Any]
            let allowed = (nested?["optionId"] as? String) == "allow-once"
            return [
                toolCallUpdateEvent(toolCallId: "tc-1",
                                    status: allowed ? "completed" : "failed",
                                    result: allowed ? "已删除 build/（演示）" : "用户拒绝了删除动作"),
                agentMessage(id: "m-final",
                             text: allowed
                                ? "已按你的允许继续执行，构建产物已清理。"
                                : "好的，已跳过删除动作，改用增量构建继续。"),
            ]
        }

        guard let method else { return [] }
        let id = request["id"]

        switch method {
        case AcpMethod.initialize:
            return [success(id: id, result: [
                "protocolVersion": 1,
                "agentInfo": ["name": "dsh-demo-peer", "version": "0.2.0-rc.2"],
                "agentCapabilities": [
                    "loadSession": false,
                    "promptCapabilities": ["image": false, "audio": false, "embeddedContext": false],
                    "mcpCapabilities": ["http": true, "sse": false, "acp": false],
                    "sessionCapabilities": ["close": [:], "list": [:], "resume": [:]],
                ],
                "instructions": "这是内置内存对端，用于在未安装 dsh runtime 时演示 ACP v1 交互。",
            ])]

        case AcpMethod.sessionNew:
            return [success(id: id, result: [
                "sessionId": sessionID,
                "modes": [
                    "currentModeId": "default",
                    "availableModes": [["id": "default", "name": "默认"], ["id": "plan", "name": "计划"]],
                ],
                // dsh 0.2 的 session/new 实测只回 sessionId + configOptions。
                "configOptions": configOptions(),
            ])]

        case AcpMethod.sessionPrompt:
            prompts += 1
            if prompts == 1 {
                return [
                    agentMessage(id: "m1", text: "收到。我先检查一下工作区，"),
                    agentMessage(id: "m1", text: "然后给出计划。"),
                    toolCallEvent(toolCallId: "tc-1", command: "rm -rf build/"),
                    permissionRequestFrame,
                    success(id: id, result: ["stopReason": "request_permission"]),
                ]
            }
            return [
                planEvent(),
                usageEvent(used: 1840, size: 128000),
                agentMessage(id: "m-\(prompts)", text: "（演示对端）这是第 \(prompts) 轮的示例回复。"),
                success(id: id, result: ["stopReason": "end_turn"]),
            ]

        case AcpMethod.sessionList:
            return [success(id: id, result: ["sessions": [
                ["sessionId": sessionID, "title": "演示会话", "cwd": NSHomeDirectory()],
            ]])]

        case AcpMethod.sessionResume:
            // dsh 0.2 的 resume 只回 configOptions（不含 sessionId）。
            return [success(id: id, result: ["configOptions": configOptions()])]

        case AcpMethod.sessionClose:
            return [success(id: id, result: [:])]

        case AcpMethod.sessionSetMode:
            return [success(id: id, result: [:])]

        case AcpMethod.sessionSetConfigOption:
            // 按 dsh AcpModelConfigError 的语义拒绝未知值：不静默接受，
            // 否则演示/测试会掩盖"值拼错"这类真实故障。
            let params = request["params"] as? [String: Any]
            let configId = params?["configId"] as? String
            let value = params?["value"] as? String
            if configId != "model" {
                return [frame(["jsonrpc": "2.0", "id": id ?? NSNull(),
                               "error": ["code": -32602,
                                         "message": "unknown session config option: \(configId ?? "nil")"]])]
            }
            guard let value, let model = demoModels.first(where: { modelValue($0) == value }) else {
                return [frame(["jsonrpc": "2.0", "id": id ?? NSNull(),
                               "error": ["code": -32602,
                                         "message": "unknown model option: \(value ?? "nil")"]])]
            }
            selectedModel = model
            // 先回响应（服务端以整份状态回答），再按 dsh 的行为广播通知。
            return [success(id: id, result: ["configOptions": configOptions()]),
                    configOptionUpdateFrame]

        default:
            // notify 等无 id 帧不回复。
            return id == nil ? [] : [frame([
                "jsonrpc": "2.0",
                "id": id ?? NSNull(),
                "error": ["code": -32601, "message": "demo peer: method not found"],
            ])]
        }
    }
}
