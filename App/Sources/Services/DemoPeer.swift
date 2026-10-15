import Foundation
import AcpClient

/// 内存脚本化 ACP 对端：在没有真实 dsh runtime / API Key 时，
/// 用它驱动完整的握手→会话→流式更新→反向审批交互。
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

    private var permissionRequestFrame: Data {
        serverRequest(id: "demo-perm-1", method: AcpMethod.requestPermission, params: [
            "sessionId": sessionID,
            // dsh 0.2 审批请求仅携带 toolCallId。
            "toolCall": ["toolCallId": "tc-1"],
            "options": [
                ["optionId": "allow-once", "name": "允许一次", "kind": "allow_once"],
                ["optionId": "reject-once", "name": "拒绝", "kind": "reject_once"],
            ],
        ])
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
                sessionEvent([
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": "tc-1",
                    "status": allowed ? "completed" : "rejected",
                ]),
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
                "capabilities": ["loadSession": false],
                "serverInfo": ["name": "dsh-demo-peer", "version": "0.2.0-rc.2"],
                "instructions": "这是内置内存对端，用于在未安装 dsh runtime 时演示 ACP v1 交互。",
            ])]

        case AcpMethod.sessionNew:
            return [success(id: id, result: ["sessionId": sessionID])]

        case AcpMethod.sessionPrompt:
            prompts += 1
            if prompts == 1 {
                return [
                    agentMessage(id: "m1", text: "收到。我先检查一下工作区，"),
                    agentMessage(id: "m1", text: "然后给出计划。"),
                    sessionEvent([
                        "sessionUpdate": "tool_call",
                        "toolCallId": "tc-1",
                        "title": "rm -rf build/",
                        "kind": "other",
                        "status": "in_progress",
                    ]),
                    permissionRequestFrame,
                    success(id: id, result: ["stopReason": "request_permission"]),
                ]
            }
            return [
                agentMessage(id: "m-\(prompts)", text: "（演示对端）这是第 \(prompts) 轮的示例回复。"),
                success(id: id, result: ["stopReason": "end_turn"]),
            ]

        case AcpMethod.sessionList:
            return [success(id: id, result: ["sessions": [
                ["sessionId": sessionID, "title": "演示会话"],
            ]])]

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
