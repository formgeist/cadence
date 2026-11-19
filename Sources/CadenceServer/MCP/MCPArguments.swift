import Foundation

/// A tool's arguments, read strictly.
///
/// A wrong type, an out-of-range number or an argument the tool does not
/// take is an `MCPToolError` naming the argument, never a silent default. A
/// model that misspells `limit` should hear about it, not get 50 rows and
/// believe it asked for 5.
public struct MCPArguments: Sendable {
    private let values: [String: JSONValue]

    /// Refuses any key not in `allowed`.
    public init(_ values: [String: JSONValue], allowed: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw MCPToolError("Unknown argument “\(unknown.prefix(64))”.")
        }
        // `null` is how some clients send "not given".
        self.values = values.filter { $0.value != .null }
    }

    public func string(_ name: String) throws -> String? {
        guard let value = values[name] else { return nil }
        guard let string = value.stringValue else { throw MCPToolError("“\(name)” must be a string.") }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func requiredString(_ name: String) throws -> String {
        guard let value = try string(name) else { throw MCPToolError("“\(name)” is required.") }
        return value
    }

    public func int(_ name: String, in range: ClosedRange<Int>? = nil) throws -> Int? {
        guard let value = values[name] else { return nil }
        guard let int = value.intValue else { throw MCPToolError("“\(name)” must be an integer.") }
        if let range, !range.contains(int) {
            throw MCPToolError("“\(name)” must be between \(range.lowerBound) and \(range.upperBound).")
        }
        return int
    }

    public func bool(_ name: String) throws -> Bool? {
        guard let value = values[name] else { return nil }
        guard let bool = value.boolValue else { throw MCPToolError("“\(name)” must be true or false.") }
        return bool
    }

    /// One of a closed set of strings.
    public func choice(_ name: String, from options: [String]) throws -> String? {
        guard let value = try string(name) else { return nil }
        guard options.contains(value) else {
            throw MCPToolError("“\(name)” must be one of: \(options.joined(separator: ", ")).")
        }
        return value
    }

    /// An ISO 8601 date or date-time. A bare date means midnight UTC.
    public func date(_ name: String) throws -> Date? {
        guard let value = try string(name) else { return nil }
        if let date = try? Date(value, strategy: .iso8601) { return date }
        if let date = try? Date(value, strategy: .iso8601.year().month().day()) { return date }
        throw MCPToolError("“\(name)” must be an ISO 8601 date, like 2026-11-01 or 2026-11-01T18:00:00Z.")
    }

    public func uuid(_ name: String) throws -> UUID? {
        guard let value = try string(name) else { return nil }
        guard let uuid = UUID(uuidString: value) else { throw MCPToolError("“\(name)” is not a valid id.") }
        return uuid
    }

    public func requiredUUID(_ name: String) throws -> UUID {
        guard let value = try uuid(name) else { throw MCPToolError("“\(name)” is required.") }
        return value
    }

    public func raw(_ name: String) -> JSONValue? { values[name] }

    /// The page a list tool returns. `defaultLimit` when not given; never more
    /// than `maximumLimit`, to keep a model's context small.
    public func page(defaultLimit: Int = 50, maximumLimit: Int = 500) throws -> (limit: Int, offset: Int) {
        (try int("limit", in: 1...maximumLimit) ?? defaultLimit,
         try int("offset", in: 0...Int(Int32.max)) ?? 0)
    }
}

/// Schema pieces the tools share.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    static func integer(_ description: String, minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "integer", "description": .string(description)]
        if let minimum { schema["minimum"] = .integer(minimum) }
        if let maximum { schema["maximum"] = .integer(maximum) }
        return .object(schema)
    }

    static func choice(_ description: String, _ options: [String]) -> JSONValue {
        ["type": "string", "description": .string(description),
         "enum": .array(options.map { .string($0) })]
    }

    static let limit = integer("Most results to return. Default 50.", minimum: 1, maximum: 500)
    static let offset = integer("Results to skip, for the next page. Default 0.", minimum: 0)
}

/// One page of a list, with what a model needs to ask for the next.
struct Page<Element> {
    var items: [Element]
    var total: Int
    var offset: Int

    init(_ all: [Element], limit: Int, offset: Int) {
        total = all.count
        self.offset = offset
        items = offset < all.count ? Array(all[offset..<min(all.count, offset + limit)]) : []
    }

    func json(_ key: String, _ transform: (Element) -> JSONValue) -> JSONValue {
        var object: [String: JSONValue] = [
            key: .array(items.map(transform)),
            "total": .integer(total),
            "offset": .integer(offset),
        ]
        if offset + items.count < total { object["nextOffset"] = .integer(offset + items.count) }
        return .object(object)
    }

    /// `12 of 340 albums` — the line the model reads.
    func summary(_ noun: String) -> String {
        guard total > 0 else { return "No \(noun)." }
        guard items.count < total else { return "\(total) \(noun)." }
        return "\(items.count) of \(total) \(noun), from \(offset)."
    }
}
