import Foundation

/// Any JSON value. HolyArrs answers many routes with loosely typed objects (and adds fields between versions),
/// so screens read what they need with fallbacks, the same way HolyArrs' own web app does, instead of failing
/// the whole screen on one changed field.
enum JSON: Decodable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    static func parse(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    subscript(key: String) -> JSON {
        if case let .object(o) = self { return o[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case let .array(a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// Non-empty strings only; numbers are given as their plain text (ids are sometimes either).
    var string: String? {
        switch self {
        case let .string(s): return s.isEmpty ? nil : s
        case let .number(n): return n.rounded() == n ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case let .number(n): return Int(n)
        case let .string(s): return Int(s)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case let .number(n): return n
        case let .string(s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool {
        switch self {
        case let .bool(b): return b
        case let .number(n): return n != 0
        case let .string(s): return s == "true" || s == "1"
        default: return false
        }
    }

    var array: [JSON] {
        if case let .array(a) = self { return a }
        return []
    }

    var object: [String: JSON] {
        if case let .object(o) = self { return o }
        return [:]
    }

    /// Strings in an array, or the "name" of each object (genres come either way).
    var names: [String] {
        array.compactMap { $0.string ?? $0["name"].string }
    }

    /// The first key that holds a value.
    func first(_ keys: String...) -> JSON {
        for k in keys where !self[k].isNull { return self[k] }
        return .null
    }
}

extension JSON {
    /// Encodes a plain Swift value for a request body.
    static func body(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8)
    }
}
