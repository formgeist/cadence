import Foundation

/// One tool as `tools/list` describes it.
public struct MCPTool: Sendable, Equatable {
    /// Hints a client may use to decide whether to ask before a call. They
    /// are hints: the server does not rely on a client honouring them.
    public struct Annotations: Sendable, Equatable {
        public var readOnly: Bool
        public var destructive: Bool
        public var idempotent: Bool

        public init(readOnly: Bool = false, destructive: Bool = false, idempotent: Bool = false) {
            self.readOnly = readOnly
            self.destructive = destructive
            self.idempotent = idempotent
        }

        public static let readOnly = Annotations(readOnly: true, idempotent: true)
    }

    public var name: String
    public var title: String?
    public var description: String
    /// A JSON Schema object for the arguments.
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public var annotations: Annotations

    public init(name: String, title: String? = nil, description: String,
                inputSchema: JSONValue = ["type": "object", "properties": [:]],
                outputSchema: JSONValue? = nil, annotations: Annotations = .init()) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.annotations = annotations
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema,
            "annotations": [
                "readOnlyHint": .bool(annotations.readOnly),
                "destructiveHint": .bool(annotations.destructive),
                "idempotentHint": .bool(annotations.idempotent),
                // The library is this Mac's own; nothing reaches outside it.
                "openWorldHint": false,
            ],
        ]
        if let title { object["title"] = .string(title) }
        if let outputSchema { object["outputSchema"] = outputSchema }
        return .object(object)
    }
}

/// What a tool call returns.
public struct MCPToolResult: Sendable, Equatable {
    /// Shown to the model. Kept short: the structured result carries the
    /// data.
    public var text: String
    public var structured: JSONValue?
    /// True when the tool ran and failed. A failure the model can act on
    /// ("no playlist with that id") is a result, not a protocol error, so the
    /// model sees it and can try again.
    public var isError: Bool

    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }

    public static func failure(_ message: String) -> MCPToolResult {
        MCPToolResult(text: message, isError: true)
    }

    var json: JSONValue {
        var object: [String: JSONValue] = [
            "content": [["type": "text", "text": .string(text)]],
            "isError": .bool(isError),
        ]
        if let structured { object["structuredContent"] = structured }
        return .object(object)
    }
}

/// Thrown by a tool for a failure the model should read. Its message goes
/// back as written, so it must never hold a path, a query or anything else
/// from inside the store. Any other error a tool throws is reported with a
/// fixed message instead.
public struct MCPToolError: Error, Sendable, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The tools a server offers. The protocol layer knows nothing about the
/// library; whatever implements this does.
public protocol MCPToolHandler: Sendable {
    var tools: [MCPTool] { get }
    /// Called only with the name of a tool in `tools`.
    func call(_ name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult
}
