import Foundation
import Network

/// Keeps track of whether the paired Mac can be reached, and reconnects
/// when it can be again.
///
/// The app shows `State` and reads the library while it is `.connected`.
/// What happens in each case:
///
/// - **The device goes offline**: `.offline`, and nothing is tried until the
///   network returns. Then it connects at once.
/// - **The Mac does not answer** (asleep, sharing off, another network):
///   `.unreachable`, retried after 2, 4, 8… seconds, up to a minute apart,
///   and at once when the network changes or `retryNow()` is called.
/// - **The Mac is busy**: waits as long as it asked, then tries again.
/// - **Something only the user can fix** (the device was unpaired, the
///   certificate changed, the versions differ): `.needsAttention`, and no
///   more tries until `retryNow()`. Retrying on its own could not help.
///
/// When a request fails with `.unreachable` while the state says
/// `.connected`, the app calls `connectionLost()` and this takes over.
public actor RemoteConnection {

    public enum State: Sendable, Equatable {
        case idle
        case connecting
        case connected(RemoteLibraryClient.ServerInfo)
        case offline
        /// The next try is due after `retryIn` seconds.
        case unreachable(retryIn: TimeInterval)
        case needsAttention(RemoteError)
    }

    public typealias Connect = @Sendable () async throws -> RemoteLibraryClient.ServerInfo
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    public private(set) var state: State = .idle

    private let connect: Connect
    private let networkUpdates: AsyncStream<Bool>
    private let sleep: Sleep
    private let firstDelay: TimeInterval
    private let maximumDelay: TimeInterval

    private var networkUp = true
    private var runner: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<State>.Continuation] = [:]

    /// A pending wait, and what ends it early.
    private var wake: (token: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var retryRequested = false

    /// Watches the device's network itself.
    public init(client: RemoteLibraryClient) {
        self.init(connect: { try await client.connect() }, network: NetworkPath.updates())
    }

    /// - Parameters:
    ///   - connect: One attempt to reach the server.
    ///   - network: Whether the device has a usable network, each time that
    ///     changes.
    ///   - sleep: How waiting is done; tests pass one that returns at once.
    public init(connect: @escaping Connect, network: AsyncStream<Bool>,
                sleep: @escaping Sleep = { try await Task.sleep(for: .seconds($0)) },
                firstDelay: TimeInterval = 2, maximumDelay: TimeInterval = 60) {
        self.connect = connect
        networkUpdates = network
        self.sleep = sleep
        self.firstDelay = firstDelay
        self.maximumDelay = maximumDelay
    }

    /// Each state from now on, starting with the current one.
    public func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream<State>.makeStream()
        let id = UUID()
        observers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { _ in Task { await self.removeObserver(id) } }
        return stream
    }

    public func start() {
        guard runner == nil else { return }
        let updates = networkUpdates
        watcher = Task {
            for await up in updates { self.networkChanged(up) }
        }
        runner = Task { await self.run() }
    }

    public func stop() {
        runner?.cancel()
        watcher?.cancel()
        runner = nil
        watcher = nil
        endWait()
        set(.idle)
    }

    /// Tries again now: after the user fixes something, or pulls to refresh.
    public func retryNow() {
        retryRequested = true
        endWait()
    }

    /// A request failed in a way that says the Mac has gone. Ignored for
    /// other errors, which are about that request, not the connection.
    public func connectionLost(_ error: RemoteError) {
        guard case .connected = state else { return }
        switch error {
        case .unreachable, .offline, .untrustedServer, .notPaired, .incompatibleServer:
            retryNow()
        default:
            break
        }
    }

    // MARK: - The loop

    private func run() async {
        var delay = firstDelay
        while !Task.isCancelled {
            guard networkUp else {
                set(.offline)
                await waitForEvent(timeout: nil)
                continue
            }
            set(.connecting)
            retryRequested = false
            do {
                let info = try await connect()
                guard !Task.isCancelled else { return }
                set(.connected(info))
                delay = firstDelay
                // Connected until the app says otherwise, or the network
                // changes under it.
                await waitForEvent(timeout: nil)
            } catch let error as RemoteError {
                guard !Task.isCancelled else { return }
                switch error {
                case .offline:
                    // The system's view of the network can lag the path
                    // monitor's, so this is retried like an unanswered Mac
                    // as well as when the network next changes.
                    set(.offline)
                    await waitForEvent(timeout: delay)
                    delay = min(delay * 2, maximumDelay)
                case .busy(let seconds):
                    set(.unreachable(retryIn: seconds))
                    await waitForEvent(timeout: seconds)
                case .untrustedServer, .notPaired, .incompatibleServer, .pairingRefused:
                    set(.needsAttention(error))
                    while !retryRequested && !Task.isCancelled { await waitForEvent(timeout: nil) }
                default:
                    set(.unreachable(retryIn: delay))
                    await waitForEvent(timeout: delay)
                    delay = min(delay * 2, maximumDelay)
                }
            } catch {
                // Cancellation, from `stop()`.
                return
            }
        }
    }

    private func networkChanged(_ up: Bool) {
        let changed = up != networkUp
        networkUp = up
        // A new network is a reason to try again whatever the last try said,
        // but not to disturb a connection that is working.
        if changed {
            if case .connected = state, up { return }
            if case .needsAttention = state { return }
            endWait()
        }
    }

    /// Waits for `timeout` seconds, or until an event ends the wait, or for
    /// ever when `timeout` is nil and nothing happens.
    private func waitForEvent(timeout: TimeInterval?) async {
        let token = UUID()
        if let timeout {
            let sleep = sleep
            Task {
                try? await sleep(timeout)
                self.endWait(token)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(); return }
                wake = (token, continuation)
            }
        } onCancel: {
            Task { await self.endWait() }
        }
    }

    /// Ends the current wait, or only the one with `token` when given, so
    /// a late timer cannot end a later wait.
    private func endWait(_ token: UUID? = nil) {
        guard let wake, token == nil || wake.token == token else { return }
        self.wake = nil
        wake.continuation.resume()
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        for continuation in observers.values { continuation.yield(new) }
    }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}

/// The device's network, from `NWPathMonitor`.
enum NetworkPath {
    static func updates() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "cadence.remote.network"))
        }
    }
}
