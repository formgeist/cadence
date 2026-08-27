import Foundation
import Observation

/// Watches `PlaybackController` and scrobbles what gets listened to — issue #95.
///
/// Like `NowPlayingCoordinator`, it observes rather than being called into, so
/// `PlaybackController` stays unaware that scrobbling exists. It lives in
/// `CadenceCore` (not the app target) so its threshold and offline-queue logic
/// can be unit-tested against a mock scrobbler and a stub clock.
///
/// The composition root feeds it track-start events (chained onto the same
/// `onTrackStarted` closure that records play history) and calls `observe` once
/// playback exists; everything else it derives from a one-second poll of
/// `playback.progress` and `playback.state`.
@MainActor
@Observable
public final class ScrobbleController {

    // MARK: Observed by the Preferences window

    /// The connected account, or `nil` when signed out.
    public private(set) var account: ScrobbleSession?

    /// Whether scrobbling is switched on. Off by default: a first launch should
    /// not send anything anywhere.
    public var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            settings.set(isEnabled, forKey: .scrobblingEnabled)
            if isEnabled { Task { await flushPending() } }
        }
    }

    /// How many plays are held waiting for the network. Drives the
    /// "N waiting to send" line.
    public private(set) var pendingCount: Int = 0

    /// The last failure worth showing, or `nil`. Cleared by the next success.
    public private(set) var lastError: String?

    public enum AuthState: Equatable {
        case idle
        case waitingForApproval
        case failed(String)
    }
    public private(set) var authState: AuthState = .idle

    /// Set when `connect()` needs a browser opened; the view clears it once it
    /// has. Kept as state rather than a callback so the flow stays observable.
    public var pendingAuthorizationURL: URL?

    public var serviceName: String { scrobbler.serviceName }
    public var isConfigured: Bool { scrobbler.isConfigured }

    // MARK: Dependencies

    private let scrobbler: any Scrobbler
    private let keychain: any KeychainStore
    private let settings: any SettingsStore
    private let now: () -> Date
    /// How often `connect()` re-checks whether the browser approval has landed.
    private let authPollInterval: Duration

    /// The keychain account the session key is filed under.
    private var keychainAccount: String { scrobbler.serviceName }

    // MARK: Queue and current-track tracking

    private var pending: [ScrobblePlay] = [] {
        didSet { pendingCount = pending.count }
    }
    private var isFlushing = false
    private var retryTask: Task<Void, Never>?

    private var currentTrackID: Track.ID?
    private var currentPlay: ScrobblePlay?
    /// Seconds actually spent listening to the current track — paused time and
    /// seek jumps don't count.
    private var listenedSeconds: TimeInterval = 0
    private var lastSampledElapsed: TimeInterval = 0
    private var scrobbledCurrent = false

    private weak var playback: PlaybackController?
    private var pollTask: Task<Void, Never>?

    /// Last.fm's rule: don't scrobble anything shorter than this.
    private static let minimumTrackLength: TimeInterval = 30
    /// …and scrobble once this much has been heard, even on a long track.
    private static let longTrackThreshold: TimeInterval = 240
    private static let maxBatch = 50

    public init(
        scrobbler: any Scrobbler,
        keychain: any KeychainStore,
        settings: any SettingsStore,
        now: @escaping () -> Date = { Date() },
        authPollInterval: Duration = .seconds(5)
    ) {
        self.scrobbler = scrobbler
        self.keychain = keychain
        self.settings = settings
        self.now = now
        self.authPollInterval = authPollInterval

        isEnabled = settings.bool(forKey: .scrobblingEnabled) ?? false
        pending = Self.decodeQueue(settings.string(forKey: .pendingScrobbles))
        pendingCount = pending.count

        if let username = settings.string(forKey: .scrobbleUsername),
           let key = keychain.string(forAccount: keychainAccount) {
            account = ScrobbleSession(key: key, username: username)
        }
    }

    // MARK: - Wiring

    /// Called once by the composition root after playback exists. Starts the
    /// poll loop and makes a first attempt at anything held from last launch.
    public func observe(_ playback: PlaybackController) {
        attach(to: playback)
        startPolling()
        Task { await flushPending() }
    }

    /// The binding without the timer — tests drive `poll()` by hand.
    func attach(to playback: PlaybackController) {
        self.playback = playback
    }

    /// Chained onto `playback.onTrackStarted` by the composition root — fires
    /// for a fresh `play(_:in:)` and for a gapless hand-off alike.
    public func trackStarted(_ track: Track) {
        finalizeCurrentTrack()

        currentTrackID = track.id
        currentPlay = ScrobblePlay(track: track, startedAt: now())
        listenedSeconds = 0
        lastSampledElapsed = 0
        scrobbledCurrent = false

        guard canScrobble, let play = currentPlay, let session = account else { return }
        Task { [scrobbler] in
            do { try await scrobbler.updateNowPlaying(play, session: session) }
            catch { /* now-playing is best effort; a miss is invisible */ }
        }
    }

    /// The composition root calls this from `applicationWillTerminate`, so a
    /// track already past the threshold at quit still counts.
    public func flushOnTermination() {
        finalizeCurrentTrack()
    }

    private var canScrobble: Bool {
        isEnabled && isConfigured && account != nil
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.poll()
            }
        }
    }

    /// One sample of playback state. Split out so tests drive it directly
    /// instead of waiting on the timer.
    func poll() {
        guard let playback else { return }

        let track = playback.currentTrack
        if track?.id != currentTrackID {
            // A track change normally arrives through `trackStarted`; this is
            // the belt-and-braces path for a stop, or an event missed.
            finalizeCurrentTrack()
            if let track {
                currentTrackID = track.id
                currentPlay = ScrobblePlay(track: track, startedAt: now())
                listenedSeconds = 0
                lastSampledElapsed = playback.progress.elapsed
                scrobbledCurrent = false
            } else {
                clearCurrent()
            }
            return
        }

        let elapsed = playback.progress.elapsed
        if playback.isPlaying {
            let delta = elapsed - lastSampledElapsed
            // Count only roughly-real-time forward motion: a seek forward is a
            // big positive jump, a seek back a negative one, neither is
            // listening.
            if delta > 0, delta <= 4 { listenedSeconds += delta }
        }
        lastSampledElapsed = elapsed
        maybeScrobbleCurrent()
    }

    private func maybeScrobbleCurrent() {
        guard !scrobbledCurrent, canScrobble, let play = currentPlay else { return }
        guard play.duration > Self.minimumTrackLength else { return }
        let target = min(play.duration / 2, Self.longTrackThreshold)
        guard listenedSeconds >= target else { return }
        scrobbledCurrent = true
        enqueue(play)
    }

    /// When the current track ends or is replaced: scrobble it if it got far
    /// enough and hasn't already been.
    private func finalizeCurrentTrack() {
        maybeScrobbleCurrent()
        clearCurrent()
    }

    private func clearCurrent() {
        currentTrackID = nil
        currentPlay = nil
        listenedSeconds = 0
        lastSampledElapsed = 0
        scrobbledCurrent = false
    }

    // MARK: - The offline queue

    private func enqueue(_ play: ScrobblePlay) {
        pending.append(play)
        persistQueue()
        Task { await flushPending() }
    }

    /// Sends as many held plays as the service will take, oldest first. Safe to
    /// call repeatedly — it no-ops while one flush is in flight.
    func flushPending() async {
        guard canScrobble, let session = account,
              !pending.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.maxBatch))
            do {
                try await scrobbler.submit(batch, session: session)
                pending.removeFirst(batch.count)
                persistQueue()
                lastError = nil
            } catch ScrobbleError.needsReauthorization {
                handleDeadSession()
                return
            } catch ScrobbleError.rejected(let message) {
                // The batch will never be accepted — drop it rather than
                // wedging the queue behind it forever.
                pending.removeFirst(batch.count)
                persistQueue()
                lastError = message
            } catch {
                lastError = Self.message(for: error)
                scheduleRetry()
                return
            }
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            await self.flushPending()
        }
    }

    private func handleDeadSession() {
        keychain.set(nil, forAccount: keychainAccount)
        account = nil
        lastError = "\(scrobbler.serviceName) sign-in expired. Reconnect in Preferences."
    }

    // MARK: - Auth

    public func connect() {
        guard isConfigured else {
            authState = .failed("No \(scrobbler.serviceName) API key is configured.")
            return
        }
        authState = .waitingForApproval
        Task { await runAuthorization() }
    }

    private func runAuthorization() async {
        do {
            let (url, token) = try await scrobbler.beginAuthorization()
            pendingAuthorizationURL = url

            // Poll for approval for a few minutes, then give up.
            for _ in 0..<60 {
                try await Task.sleep(for: authPollInterval)
                do {
                    let session = try await scrobbler.completeAuthorization(token: token)
                    applySession(session)
                    authState = .idle
                    await flushPending()
                    return
                } catch ScrobbleError.authorizationPending {
                    continue
                }
            }
            authState = .failed("Timed out waiting for approval on \(scrobbler.serviceName).")
        } catch {
            authState = .failed(Self.message(for: error))
        }
    }

    private func applySession(_ session: ScrobbleSession) {
        keychain.set(session.key, forAccount: keychainAccount)
        settings.set(session.username, forKey: .scrobbleUsername)
        settings.set(scrobbler.serviceName, forKey: .scrobbleService)
        account = session
        // Connecting is a clear "yes, scrobble" — flip it on if it wasn't.
        if !isEnabled { isEnabled = true }
    }

    public func signOut() {
        keychain.set(nil, forAccount: keychainAccount)
        settings.set(nil as String?, forKey: .scrobbleUsername)
        account = nil
        authState = .idle
        lastError = nil
        // Held plays can't be sent without a session, and they belong to the
        // account that just left.
        pending = []
        persistQueue()
    }

    // MARK: - Persistence

    private func persistQueue() {
        settings.set(Self.encodeQueue(pending), forKey: .pendingScrobbles)
    }

    private static func encodeQueue(_ plays: [ScrobblePlay]) -> String? {
        guard !plays.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return (try? encoder.encode(plays)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeQueue(_ raw: String?) -> [ScrobblePlay] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([ScrobblePlay].self, from: data)) ?? []
    }

    private static func message(for error: Error) -> String {
        switch error {
        case ScrobbleError.transient(let detail): detail
        case ScrobbleError.rejected(let detail): detail
        case ScrobbleError.notConfigured: "No API key is configured."
        case ScrobbleError.malformedResponse: "The service sent a response Cadence could not read."
        default: error.localizedDescription
        }
    }
}
