import Foundation

/// Any JSON value, for engine results whose shape the app passes along or ignores.
enum JSONValue: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
    /// As JSONSerialization objects, to send back to the engine.
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? Int64(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    /// A copy of this object with `key` set to an encodable value.
    func setting<T: Encodable>(_ key: String, to value: T) throws -> JSONValue {
        guard case .object(var object) = self else { throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: [], debugDescription: "not an object")) }
        object[key] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        return .object(object)
    }
    /// The value at `key` of this object, decoded.
    func decoded<T: Decodable>(_ key: String, as type: T.Type) throws -> T {
        guard case .object(let object) = self, let value = object[key] else { throw DecodingError.valueNotFound(T.self, .init(codingPath: [], debugDescription: key)) }
        return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }
}
