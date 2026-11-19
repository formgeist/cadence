import Foundation

/// The JSON-RPC 2.0 pieces MCP is built on. Only what the server needs: it
/// receives requests and notifications, and answers requests. It never sends
/// a request of its own.
enum JSONRPC {

    /// What one message body turned out to be.
    enum Message: Equatable {
        /// Has an id and wants an answer.
        case request(id: JSONValue, method: String, params: [String: JSONValue])
        /// No id: nothing is sent back.
        case notification(method: String)
        /// A client's answer to a server request. This server never sends
        /// one, so there is nothing to match it to; it is accepted and
        /// dropped.
        case response
    }

    struct ErrorObject: Error, Equatable {
        var code: Int
        var message: String

        static func parseError() -> ErrorObject {
            ErrorObject(code: -32700, message: "The body is not JSON.")
        }
        static func invalidRequest(_ message: String) -> ErrorObject {
            ErrorObject(code: -32600, message: message)
        }
        static func methodNotFound(_ method: String) -> ErrorObject {
            // The method name is echoed back only after it has been bounded,
            // so a long one cannot make the answer long.
            ErrorObject(code: -32601, message: "Unknown method: \(method.prefix(64))")
        }
        static func invalidParams(_ message: String) -> ErrorObject {
            ErrorObject(code: -32602, message: message)
        }
        static func internalError() -> ErrorObject {
            ErrorObject(code: -32603, message: "Internal error.")
        }
    }

    /// Reads one message, or the error to answer it with.
    ///
    /// Batches are refused. The 2025-06-18 revision of MCP removed them, and
    /// one message per HTTP request keeps the answer to "which request is this
    /// the response to?" trivial.
    static func parse(_ body: Data) -> Result<Message, ErrorObject> {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return .failure(.parseError())
        }
        if case .array = value {
            return .failure(.invalidRequest("Batch requests are not supported."))
        }
        guard let object = value.objectValue else {
            return .failure(.invalidRequest("A message is a JSON object."))
        }
        guard object["jsonrpc"] == "2.0" else {
            return .failure(.invalidRequest("Only JSON-RPC 2.0 is supported."))
        }

        guard let methodValue = object["method"] else {
            // No method: a response, if it has the shape of one.
            if object["id"] != nil, object["result"] != nil || object["error"] != nil {
                return .success(.response)
            }
            return .failure(.invalidRequest("A request needs a method."))
        }
        guard let method = methodValue.stringValue, !method.isEmpty else {
            return .failure(.invalidRequest("The method must be a string."))
        }

        var params: [String: JSONValue] = [:]
        switch object["params"] {
        case nil: break
        case .object(let value)?: params = value
        // By-position parameters are legal JSON-RPC, but no MCP method takes
        // them.
        default: return .failure(.invalidRequest("Params must be an object."))
        }

        guard let id = object["id"] else { return .success(.notification(method: method)) }
        switch id {
        case .string, .integer: break
        // Null ids are for errors the server could not tie to a request, and
        // MCP rules them out for requests.
        default: return .failure(.invalidRequest("The id must be a string or an integer."))
        }
        return .success(.request(id: id, method: method, params: params))
    }

    static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    /// `id` is null when the request could not be read far enough to find
    /// one.
    static func error(id: JSONValue?, _ error: ErrorObject) -> JSONValue {
        ["jsonrpc": "2.0", "id": id ?? .null,
         "error": ["code": .integer(error.code), "message": .string(error.message)]]
    }
}
