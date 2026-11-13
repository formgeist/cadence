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

    /// HTTPS, presenting `identity`. This is the listener a release build
    /// uses, and the only one it has.
    ///
    /// TLS 1.3 only. Both ends are Cadence, on current systems, so there is
    /// no older client to accommodate and no older protocol to leave open.
    ///
    /// - Parameters:
    ///   - port: Nil lets the system choose one.
    ///   - loopbackOnly: Binds to 127.0.0.1 alone, for tests. The real server
    ///     listens on the local network.
    public static func tls(
        identity: ServerIdentity, port: UInt16? = nil, loopbackOnly: Bool = false,
        limits: Limits = Limits(), handler: @escaping Handler
    ) throws -> HTTPListener {
        let options = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw ListenerError.failed("identity")
        }
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(
            options.securityProtocolOptions, .TLSv13)

        let parameters = NWParameters(tls: options)
        let endpointPort = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        if loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            parameters.acceptLocalOnly = true
        } else if port != nil {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.any), port: endpointPort)
        }
        return try HTTPListener(parameters: parameters, limits: limits, handler: handler)
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
            guard let file = response.file, includingBody else {
                raw.send(content: response.serialized(includingBody: includingBody),
                         completion: .contentProcessed { [weak self] _ in self?.close() })
                return
            }

            // Open before promising anything. If the file has gone, or is no
            // longer the size the response was built for, the client gets an
            // honest error instead of a head followed by a short body.
            guard let opened = FileSource.open(file.url),
                  opened.size >= file.offset + file.length,
                  (try? opened.handle.seek(toOffset: file.offset)) != nil else {
                raw.send(content: HTTPResponse.empty(.internalServerError).serialized(),
                         completion: .contentProcessed { [weak self] _ in self?.close() })
                return
            }
            let source = OpenFile(opened.handle)
            raw.send(content: response.serializedHead(),
                     completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else {
                    source.close()
                    self?.close()
                    return
                }
                self.pump(source, remaining: file.length)
            })
        }

        /// Sends the file a piece at a time. Each piece is read only once the
        /// one before it has been handed to the network, so a slow client
        /// holds one piece in memory, not the file.
        private func pump(_ source: OpenFile, remaining: UInt64) {
            guard !isClosed, remaining > 0 else {
                source.close()
                close()
                return
            }
            let count = Int(min(remaining, UInt64(Self.chunkSize)))
            // Reading can block on a sleeping disk. It happens off the
            // listener's queue so other connections keep moving.
            Self.files.async { [queue] in
                let chunk = source.read(count)
                queue.async {
                    guard let chunk, !chunk.isEmpty, !self.isClosed else {
                        source.close()
                        self.close()
                        return
                    }
                    self.raw.send(content: chunk, completion: .contentProcessed { error in
                        if error != nil {
                            source.close()
                            self.close()
                        } else {
                            self.pump(source, remaining: remaining - UInt64(chunk.count))
                        }
                    })
                }
            }
        }

        private static let chunkSize = 64 * 1024
        private static let files = DispatchQueue(
            label: "cadence.server.files", qos: .userInitiated, attributes: .concurrent)

        /// A file being sent. One reader at a time, by construction: the next
        /// read is requested only from the completion of the previous send.
        private final class OpenFile: @unchecked Sendable {
            private let handle: FileHandle
            init(_ handle: FileHandle) { self.handle = handle }
            func read(_ count: Int) -> Data? { try? handle.read(upToCount: count) }
            func close() { try? handle.close() }
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
