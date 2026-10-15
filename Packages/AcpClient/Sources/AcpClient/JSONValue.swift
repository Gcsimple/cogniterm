import Foundation

/// 轻量动态 JSON 值，用于 ACP 帧中未强类型化的字段（如 `params`/`result` 透传）。
public enum JSONValue: Sendable, Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int64(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(_ key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// 重新编码为 JSON Data，供强类型 Decodable 二次解码。
    public func reencoded(using encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        try encoder.encode(self)
    }
}

/// JSON-RPC id 可以是字符串或整数。
public enum JSONId: Hashable, Sendable, Codable, CustomStringConvertible {
    case string(String)
    case int(Int64)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .int(try container.decode(Int64.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .string(let value): return value
        case .int(let value): return String(value)
        }
    }
}

/// 包装任意 Encodable，避免在泛型请求方法里引入 existentials 编码问题。
struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self._encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
