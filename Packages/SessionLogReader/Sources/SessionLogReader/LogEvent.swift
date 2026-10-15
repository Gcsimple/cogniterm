import Foundation
import AcpClient

/// dsh session JSONL 中的一行：有序号、原始字节、宽松解码的 JSON 与归一化 kind。
public struct LogEvent: Sendable {
    public let seq: Int
    public let data: Data
    public let json: JSONValue?

    public init(seq: Int, data: Data, json: JSONValue?) {
        self.seq = seq
        self.data = data
        self.json = json
    }

    /// dsh 0.2 的事件名散落在 type / event / kind / name 等键，按优先级归一化。
    public var kind: String? {
        guard let obj = json?.objectValue else { return nil }
        for key in ["type", "event", "kind", "name"] {
            if let value = obj[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    public var timestamp: Date? {
        guard let obj = json?.objectValue else { return nil }
        for key in ["timestamp", "time", "ts", "createdAt"] {
            guard let raw = obj[key] else { continue }
            if let millis = raw.intValue {
                // 秒/毫秒启发式：13 位视为毫秒。
                return Date(timeIntervalSince1970: millis > 10_000_000_000 ? Double(millis) / 1000
                                                                         : Double(millis))
            }
            if let text = raw.stringValue, let seconds = Double(text) {
                return Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    /// 统一取载荷对象：data / payload / detail / update 之一，否则取整行。
    public var payload: JSONValue {
        if let obj = json?.objectValue {
            for key in ["data", "payload", "detail", "update"] {
                if let value = obj[key] { return value }
            }
        }
        return json ?? .null
    }

    public func field(_ path: String...) -> JSONValue? {
        var current = json
        for key in path {
            current = current?[key]
        }
        return current
    }
}

public enum JSONLLine {
    /// 解析一行 JSON；空行/坏行返回 nil（规约：坏帧忽略）。
    public static func parse(_ data: Data, seq: Int, decoder: JSONDecoder = .acp) -> LogEvent? {
        let trimmed = data.filter { $0 != 0x0D }
        guard !trimmed.isEmpty else { return nil }
        guard let json = try? decoder.decode(JSONValue.self, from: trimmed) else { return nil }
        return LogEvent(seq: seq, data: trimmed, json: json)
    }
}
