import Foundation

/// NOTE: declared members (text, string, int, array, ...) shadow keys of the same name; use `j["text"]` for such keys.
/// Lightweight dynamic JSON value used to walk InnerTube responses, which are
/// deeply nested and change shape often. Missing keys return `.null` instead of failing.
@dynamicMemberLookup
enum JSON: Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(data: Data) throws {
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: obj)
    }

    init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) } else { self = .number(n.doubleValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    subscript(dynamicMember key: String) -> JSON { self[key] }

    subscript(key: String) -> JSON {
        if case .object(let d) = self { return d[key] ?? .null }
        return .null
    }

    subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    var isNull: Bool { if case .null = self { return true }; return false }
    var exists: Bool { !isNull }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var int: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true"
        case .number(let n): return n != 0
        default: return nil
        }
    }

    var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    var object: [String: JSON] { if case .object(let d) = self { return d }; return [:] }

    /// YouTube text: `{simpleText}` or `{runs:[{text}]}` or `{content}` (view models).
    var text: String? {
        if let s = self.simpleText.string { return s }
        let runs = self.runs.array
        if !runs.isEmpty { return runs.compactMap { $0["text"].string }.joined() }
        if let s = self.content.string { return s }
        if let s = self.string { return s }
        return nil
    }

    /// Recursively finds every value stored under `key`.
    func findAll(_ key: String, limit: Int = .max) -> [JSON] {
        var out: [JSON] = []
        func walk(_ j: JSON) {
            if out.count >= limit { return }
            switch j {
            case .object(let d):
                if let v = d[key] { out.append(v) }
                for (_, v) in d { walk(v) }
            case .array(let a):
                for v in a { walk(v) }
            default: break
            }
        }
        walk(self)
        return out
    }

    func first(_ key: String) -> JSON { findAll(key, limit: 1).first ?? .null }

    /// Best thumbnail url from `{thumbnails:[...]}` or `{sources:[...]}`.
    var bestThumbnail: URL? {
        var list = self.thumbnails.array
        if list.isEmpty { list = self.sources.array }
        if list.isEmpty { list = self.image.sources.array }
        let best = list.max { ($0.width.int ?? 0) < ($1.width.int ?? 0) }
        guard var s = best?.url.string else { return nil }
        if s.hasPrefix("//") { s = "https:" + s }
        return URL(string: s)
    }

    // MARK: Serialization

    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let d): return d.mapValues { $0.anyValue }
        }
    }

    func data() -> Data {
        (try? JSONSerialization.data(withJSONObject: anyValue, options: [.fragmentsAllowed])) ?? Data()
    }
}

extension Dictionary where Key == String, Value == Any {
    func jsonData() -> Data {
        (try? JSONSerialization.data(withJSONObject: self)) ?? Data()
    }
}
