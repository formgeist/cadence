import Foundation

/// Downloads that carry on while the app is suspended or not running, so a
/// large album finishes with the phone locked.
///
/// A background `URLSession` hands its tasks to the system, which keeps each
/// request until it is done. So every request here is signed with a
/// download token (`RemoteLibraryClient.downloadToken(songID:)`), never the
/// API key: a token is worth one song for a few hours, and stops working
/// when the device is unpaired or Cadence quits on the Mac.
///
/// - **Pinned.** The server-trust challenge comes to this object as the
///   session's delegate, and is answered with the same fingerprint check as
///   every other request. The system wakes the app to ask.
/// - **Straight into the kept folder.** A finished file is moved into
///   `RemoteDownloads` before the delegate call returns, as the system
///   requires; it never passes through the playback cache.
/// - **Survives the app.** Create one per paired Mac at launch, with the
///   same identifier, and it picks up whatever finished while the app was
///   gone. Each task carries its song's id and suffix in `taskDescription`.
///
/// Results arrive on `events()`.
public final class RemoteBackgroundDownloads: NSObject, @unchecked Sendable {

    public enum Event: Sendable, Equatable {
        case kept(songID: String)
        /// The Mac refused the token: it expired, or Cadence was restarted
        /// there. Ask for a new one and start the song again.
        case needsToken(songID: String)
        /// The song did not arrive.
        case failed(songID: String, RemoteError)
    }

    /// The identifier for a paired Mac's background session.
    public static func identifier(fingerprint: String) -> String {
        "com.formgeist.cadence.downloads." + String(fingerprint.lowercased().prefix(16))
    }

    private let folder: RemoteDownloads
    private let fingerprint: String
    private let lock = NSLock()
    private var session: URLSession!
    private var observers: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var finishedEvents: (@Sendable () -> Void)?
    /// Tasks the pin check refused, told apart from ones cancelled here.
    private var refused: Set<Int> = []

    /// - Parameters:
    ///   - configuration: Leave nil in the app for a background session
    ///     named by `identifier`. Tests pass an ephemeral one, which runs the
    ///     same delegate code without the system's daemon.
    public init(identifier: String, fingerprint: String, folder: RemoteDownloads,
                configuration: URLSessionConfiguration? = nil) {
        self.folder = folder
        self.fingerprint = fingerprint.lowercased()
        super.init()
        let configuration = configuration ?? {
            let background = URLSessionConfiguration.background(withIdentifier: identifier)
            // Start now, not when the system judges it convenient, and wake
            // the app when tasks finish so files reach the kept folder.
            background.isDiscretionary = false
            background.sessionSendsLaunchEvents = true
            return background
        }()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        // Two at a time, leaving room within the Mac's four streams per
        // device for playback.
        configuration.httpMaximumConnectionsPerHost = 2
        // A token lasts six hours; a task still waiting after that would be
        // refused anyway.
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Every result from now on.
    public func events() -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let id = UUID()
        lock.withLock { observers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { self?.observers[id] = nil }
        }
        return stream
    }

    /// Starts downloading a song with a request from
    /// `RemoteLibraryClient.downloadRequest(songID:token:)`. A song already
    /// on its way is left alone.
    public func start(songID: String, suffix: String, request: URLRequest) async {
        guard await !inFlight().contains(songID) else { return }
        let task = session.downloadTask(with: request)
        task.taskDescription = Self.describe(songID: songID, suffix: suffix)
        task.resume()
    }

    /// The songs the system is still working on, this launch or a previous one.
    public func inFlight() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }
            .compactMap { $0.taskDescription.flatMap(Self.parse)?.songID })
    }

    /// Stops the given songs, or every song when nil.
    public func cancel(songIDs: Set<String>? = nil) async {
        for task in await session.allTasks {
            guard let songID = task.taskDescription.flatMap(Self.parse)?.songID else { continue }
            if songIDs?.contains(songID) ?? true { task.cancel() }
        }
    }

    /// The handler the app is given in
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`,
    /// called once every event the system saved for this session has been
    /// delivered.
    public func setFinishedEventsHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { finishedEvents = handler }
    }

    public func invalidate() {
        session.finishTasksAndInvalidate()
    }

    // MARK: - Private

    private func emit(_ event: Event) {
        let continuations = lock.withLock { Array(observers.values) }
        for continuation in continuations { continuation.yield(event) }
    }

    static func describe(songID: String, suffix: String) -> String { "\(songID)|\(suffix)" }

    static func parse(_ description: String) -> (songID: String, suffix: String)? {
        let parts = description.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    /// Moves a downloaded file into the kept folder, or says why it can't.
    /// Separate from the delegate so the rules can be tested without one.
    static func finish(_ file: URL, response: URLResponse?, description: String?,
                       into folder: RemoteDownloads) -> Event? {
        guard let (songID, suffix) = description.flatMap(parse) else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        guard let http = response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: file)
            return .failed(songID: songID, .invalidResponse)
        }
        let isEnvelope = http.value(forHTTPHeaderField: "Content-Type")?.contains("json") == true
        guard http.statusCode == 200, !isEnvelope else {
            let body = (try? Data(contentsOf: file)) ?? Data()
            try? FileManager.default.removeItem(at: file)
            let error = RemoteLibraryClient.failure(http, body: body)
            if case .server(code: 50, _) = error { return .needsToken(songID: songID) }
            return .failed(songID: songID, error)
        }
        do {
            _ = try folder.keep(file, songID: songID, suffix: suffix, moving: true)
            return .kept(songID: songID)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return .failed(songID: songID, .storageFailed(message: error.localizedDescription))
        }
    }
}

extension RemoteBackgroundDownloads: URLSessionDownloadDelegate {

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // The file is gone once this returns, so it is moved now.
        if let event = Self.finish(location, response: downloadTask.response,
                                   description: downloadTask.taskDescription, into: folder) {
            emit(event)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: (any Error)?) {
        guard let error, let songID = task.taskDescription.flatMap(Self.parse)?.songID else { return }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled {
                // Cancelled here, or refused by the pin check below.
                let wasRefused = lock.withLock { refused.remove(task.taskIdentifier) != nil }
                if wasRefused { emit(.failed(songID: songID, .untrustedServer)) }
                return
            }
            emit(.failed(songID: songID, RemoteError.transport(urlError)))
        } else {
            emit(.failed(songID: songID, .unreachable))
        }
    }

    // Per task, not per session: a session-level handler would take the
    // server-trust challenge without saying which task it belongs to.
    public func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first,
              PinnedSession.fingerprint(of: leaf) == fingerprint
        else {
            lock.withLock { _ = refused.insert(task.taskIdentifier) }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { finishedEvents = nil }
            return finishedEvents
        }
        DispatchQueue.main.async { handler?() }
    }
}
