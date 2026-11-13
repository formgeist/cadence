import Foundation
import Network

/// Accepts connections and turns each into one request and one response.
///
/// The only way to make one from outside this module is `loopback`, and that
/// exists in debug builds only. A release build therefore contains no way to
/// start a plain-HTTP listener at all, which is the guarantee the build plan
/// asks for: release traffic is TLS or nothing. The TLS listener that Phase 3
/// adds goes through the same initialiser with different parameters.
public final class HTTPListener: @unchecked Sendable {

    public struct Limits: Sendable {
        public var parser = HTTPRequestParser.Limits()
        /// Connections open at once. One over the limit is closed unanswered.
        public var connections = 32
        /// How long a client has to send its request head.
        public var headTimeout: TimeInterval = 10

        public init() {}
    }

    public enum ListenerError: Error {
        case failed(String)
        case stopped
    }

    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let handler: Handler
    private let limits: Limits
    /// Guards `open`. Connection callbacks arrive on `queue`, but `stop` and
    /// `deinit` can come from anywhere.
    private let queue = DispatchQueue(label: "cadence.server.listener")
    private var open: [ObjectIdentifier: Connection] = [:]

    init(parameters: NWParameters, limits: Limits, handler: @escaping Handler) throws {
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.limits = limits
    }

    #if DEBUG
    /// Plain HTTP on the loopback interface, on a port the system picks. For
    /// `curl` and tests while the server is being built. Nothing off this
    /// machine can reach it, and it does not exist in a release build.
    public static func loopback(
        limits: Limits = Limits(), handler: @escaping Handler
    ) throws -> HTTPListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        return try HTTPListener(parameters: parameters, limits: limits, handler: handler)
    }
    #endif

    /// Starts listening and returns the port once the listener is ready.
    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            // `stateUpdateHandler` fires again on later state changes; the
            // continuation must be resumed for the first outcome only.
            let pending = OneShot(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        pending.resume(.success(port))
                    } else {
                        pending.resume(.failure(ListenerError.failed("no port")))
                    }
                case .failed(let error):
                    pending.resume(.failure(ListenerError.failed(String(describing: error))))
                case .cancelled:
                    pending.resume(.failure(ListenerError.stopped))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        queue.async {
            for connection in self.open.values { connection.close() }
            self.open.removeAll()
        }
    }

    deinit { listener.cancel() }

    /// Resumes a continuation once and ignores every later attempt. Only
    /// ever touched on the listener's queue.
    private final class OneShot: @unchecked Sendable {
        private var continuation: CheckedContinuation<UInt16, any Error>?
        init(_ continuation: CheckedContinuation<UInt16, any Error>) {
            self.continuation = continuation
        }
        func resume(_ result: Result<UInt16, any Error>) {
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    // MARK: - Connections

    private func accept(_ raw: NWConnection) {
        guard open.count < limits.connections else {
            raw.cancel()
            return
        }
        let connection = Connection(raw, queue: queue, limits: limits, handler: handler)
        let id = ObjectIdentifier(connection)
        open[id] = connection
        connection.onClose = { [weak self] in self?.open[id] = nil }
        connection.start()
    }

    /// One connection, one request, one response, then closed. Confined to
    /// the listener's queue; the handler runs off it and hops back to send.
    private final class Connection: @unchecked Sendable {
        private let raw: NWConnection
        private let queue: DispatchQueue
        private let limits: Limits
        private let handler: Handler
        private var buffer = Data()
        private var isClosed = false
        private var isAnswering = false
        var onClose: (() -> Void)?

        init(_ raw: NWConnection, queue: DispatchQueue, limits: Limits, handler: @escaping Handler) {
            self.raw = raw
            self.queue = queue
            self.limits = limits
            self.handler = handler
        }

        func start() {
            raw.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed, .cancelled: self?.close()
                default: break
                }
            }
            raw.start(queue: queue)
            // A client that connects and says nothing must not hold a slot.
            queue.asyncAfter(deadline: .now() + limits.headTimeout) { [weak self] in
                guard let self, !self.isAnswering else { return }
                self.send(.empty(.requestTimeout), includingBody: true)
            }
            receive()
        }

        private func receive() {
            raw.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                [weak self] data, _, isComplete, error in
                guard let self, !self.isClosed, !self.isAnswering else { return }
                if let data { self.buffer.append(data) }

                switch HTTPRequestParser.parse(self.buffer, limits: self.limits.parser) {
                case .request(let request):
                    self.isAnswering = true
                    let handler = self.handler
                    Task {
                        let response = await handler(request)
                        self.queue.async {
                            self.send(response, includingBody: request.method != .head)
                        }
                    }
                case .failure(let status):
                    self.send(.empty(status), includingBody: true)
                case .incomplete:
                    if isComplete || error != nil {
                        self.close()
                    } else {
                        self.receive()
                    }
                }
            }
        }

        private func send(_ response: HTTPResponse, includingBody: Bool) {
            guard !isClosed else { return }
            isAnswering = true
            raw.send(content: response.serialized(includingBody: includingBody),
                     completion: .contentProcessed { [weak self] _ in self?.close() })
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            raw.cancel()
            onClose?()
            onClose = nil
        }
    }
}
