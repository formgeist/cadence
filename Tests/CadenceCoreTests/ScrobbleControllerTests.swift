import Testing
import Foundation
@testable import CadenceCore

@MainActor
@Suite("ScrobbleController")
struct ScrobbleControllerTests {

    // MARK: Fixture

    /// Everything a test needs, wired the way `AppContainer` wires it: the
    /// scrobbler's now-playing feed comes off `PlaybackController.onTrackStarted`,
    /// and the threshold is reached by sampling `poll()` by hand.
    struct Rig {
        let controller: ScrobbleController
        let mock: MockScrobbler
        let playback: PlaybackController
        let engine: SpyEngine
        let settings: InMemorySettingsStore
        let keychain: InMemoryKeychainStore
        /// The fixed "wall clock" every play is stamped against.
        let now: Date
    }

    static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    func makeRig(
        configured: Bool = true,
        enabled: Bool = true,
        signedIn: Bool = true
    ) async -> Rig {
        let settings = InMemorySettingsStore()
        let keychain = InMemoryKeychainStore()
        if enabled { settings.set(true, forKey: .scrobblingEnabled) }
        if signedIn {
            settings.set("listener", forKey: .scrobbleUsername)
            keychain.set("session-key", forAccount: "Mock")
        }
        let mock = MockScrobbler(configured: configured)

        let controller = ScrobbleController(
            scrobbler: mock, keychain: keychain, settings: settings,
            now: { Self.fixedNow }, authPollInterval: .milliseconds(5))

        let engine = SpyEngine()
        let playback = PlaybackController(engine: engine)
        playback.onTrackStarted = { [weak controller] in controller?.trackStarted($0) }
        controller.attach(to: playback)

        return Rig(controller: controller, mock: mock, playback: playback,
                   engine: engine, settings: settings, keychain: keychain, now: Self.fixedNow)
    }

    func track(_ title: String, seconds: TimeInterval = 200) -> Track {
        Track(url: URL(fileURLWithPath: "/music/\(title).flac"),
              title: title, artist: "Artist", albumTitle: "Album", duration: seconds)
    }

    /// Simulate `seconds` of real-time listening: nudge the position forward a
    /// second at a time and let the controller sample each step.
    func listen(_ rig: Rig, seconds: Int) {
        for _ in 0..<seconds {
            rig.playback.seek(to: rig.playback.progress.elapsed + 1)
            rig.controller.poll()
        }
    }

    /// Let detached `Task { await flushPending() }` work drain.
    func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(30))
    }

    func start(_ rig: Rig, _ track: Track) async {
        rig.playback.play(track, in: [track])
        await rig.engine.emit(.started(track.url))
        await settle()
    }

    // MARK: Now playing

    @Test("A now-playing update is sent when a track starts")
    func nowPlayingOnStart() async {
        let rig = await makeRig()
        await start(rig, track("Undertow"))

        #expect(await rig.mock.nowPlaying.map(\.track) == ["Undertow"])
    }

    @Test("Nothing is sent while scrobbling is switched off")
    func silentWhenDisabled() async {
        let rig = await makeRig(enabled: false)
        await start(rig, track("Undertow"))
        listen(rig, seconds: 150)
        await settle()

        #expect(await rig.mock.nowPlaying.isEmpty)
        #expect(await rig.mock.submitted.isEmpty)
    }

    @Test("Nothing is sent while signed out")
    func silentWhenSignedOut() async {
        let rig = await makeRig(signedIn: false)
        await start(rig, track("Undertow"))
        listen(rig, seconds: 150)
        await settle()

        #expect(await rig.mock.submitted.isEmpty)
    }

    // MARK: Threshold

    @Test("A track scrobbles once it passes the halfway mark")
    func scrobblesAtHalfway() async {
        let rig = await makeRig()
        await start(rig, track("Slow Hours", seconds: 200))

        listen(rig, seconds: 99)
        await settle()
        #expect(await rig.mock.submitted.isEmpty)

        listen(rig, seconds: 2)   // now past 100s
        await settle()
        #expect(await rig.mock.submitted.map(\.track) == ["Slow Hours"])
    }

    @Test("A long track scrobbles after four minutes, not at its midpoint")
    func scrobblesAtFourMinutes() async {
        let rig = await makeRig()
        await start(rig, track("Nocturne", seconds: 3600))

        listen(rig, seconds: 239)
        await settle()
        #expect(await rig.mock.submitted.isEmpty)

        listen(rig, seconds: 2)
        await settle()
        #expect(await rig.mock.submitted.map(\.track) == ["Nocturne"])
    }

    @Test("The scrobble is stamped with when the track started, not when it crossed the line")
    func timestampIsStartTime() async {
        let rig = await makeRig()
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 110)
        await settle()

        let submitted = await rig.mock.submitted
        #expect(submitted.first?.startedAt == Self.fixedNow)
    }

    @Test("A track under 30 seconds never scrobbles")
    func tooShortToScrobble() async {
        let rig = await makeRig()
        await start(rig, track("Interlude", seconds: 20))
        listen(rig, seconds: 20)
        await settle()

        #expect(await rig.mock.submitted.isEmpty)
    }

    @Test("A track skipped before the threshold does not scrobble when the next one starts")
    func skippedEarlyDoesNotScrobble() async {
        let rig = await makeRig()
        await start(rig, track("First", seconds: 200))
        listen(rig, seconds: 30)

        await start(rig, track("Second", seconds: 200))
        await settle()

        #expect(await rig.mock.submitted.isEmpty)
    }

    @Test("Only one scrobble per play, however long it keeps running")
    func scrobblesOnce() async {
        let rig = await makeRig()
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 180)
        await settle()

        #expect(await rig.mock.submitted.count == 1)
    }

    // MARK: Offline queue

    @Test("A failed submit holds the play for retry")
    func failedSubmitQueues() async {
        let rig = await makeRig()
        await rig.mock.setNextError(.transient("offline"), sticky: true)
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 110)
        await settle()

        #expect(await rig.mock.submitted.isEmpty)
        #expect(rig.controller.pendingCount == 1)
        #expect(rig.controller.lastError == "offline")
    }

    @Test("The held queue flushes on the next success")
    func queueFlushesLater() async {
        let rig = await makeRig()
        await rig.mock.setNextError(.transient("offline"), sticky: true)
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 110)
        await settle()
        #expect(rig.controller.pendingCount == 1)

        await rig.mock.setNextError(nil)
        await rig.controller.flushPending()

        #expect(await rig.mock.submitted.map(\.track) == ["Slow Hours"])
        #expect(rig.controller.pendingCount == 0)
        #expect(rig.controller.lastError == nil)
    }

    @Test("A permanently rejected batch is dropped rather than wedging the queue")
    func rejectedBatchDropped() async {
        let rig = await makeRig()
        await rig.mock.setNextError(.rejected("timestamp too old"), sticky: true)
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 110)
        await settle()

        #expect(rig.controller.pendingCount == 0)
        #expect(rig.controller.lastError == "timestamp too old")
    }

    @Test("A held queue survives a relaunch")
    func queuePersists() async {
        let rig = await makeRig()
        await rig.mock.setNextError(.transient("offline"), sticky: true)
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 110)
        await settle()
        #expect(rig.controller.pendingCount == 1)

        let reloaded = ScrobbleController(
            scrobbler: MockScrobbler(), keychain: rig.keychain, settings: rig.settings)
        #expect(reloaded.pendingCount == 1)
    }

    @Test("A dead session key stops the queue and signs the account out")
    func deadSessionSignsOut() async {
        let rig = await makeRig()
        await rig.mock.setNextError(.needsReauthorization, sticky: true)
        await start(rig, track("Slow Hours", seconds: 200))
        listen(rig, seconds: 110)
        await settle()

        #expect(rig.controller.account == nil)
        #expect(rig.keychain.string(forAccount: "Mock") == nil)
    }

    // MARK: Auth

    @Test("Completing authorization stores the session in the keychain and the name in settings")
    func authStoresSession() async {
        let rig = await makeRig(enabled: false, signedIn: false)
        await rig.mock.approve(ScrobbleSession(key: "fresh-key", username: "vera"))

        rig.controller.connect()
        // beginAuthorization → pendingAuthorizationURL, then the poll succeeds.
        try? await Task.sleep(for: .milliseconds(60))

        #expect(rig.controller.account?.username == "vera")
        #expect(rig.keychain.string(forAccount: "Mock") == "fresh-key")
        #expect(rig.settings.string(forKey: .scrobbleUsername) == "vera")
        #expect(rig.controller.isEnabled)   // connecting is a clear yes
    }

    @Test("Signing out clears the session everywhere")
    func signOutClears() async {
        let rig = await makeRig()
        #expect(rig.controller.account != nil)

        rig.controller.signOut()

        #expect(rig.controller.account == nil)
        #expect(rig.keychain.string(forAccount: "Mock") == nil)
        #expect(rig.settings.string(forKey: .scrobbleUsername) == nil)
    }

    @Test("Connecting is refused when no API key is configured")
    func connectNeedsConfiguration() async {
        let rig = await makeRig(configured: false, enabled: false, signedIn: false)
        rig.controller.connect()

        #expect(rig.controller.authState == .failed("No Mock API key is configured."))
    }
}

// MARK: - Last.fm request signing

@Suite("LastFMScrobbler signing")
struct LastFMSigningTests {

    @Test("An empty parameter set signs as the MD5 of the empty string")
    func emptySignature() {
        #expect(LastFMScrobbler.signature([:], secret: "")
            == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test("Parameters concatenate as name+value, sorted, with the secret appended")
    func knownVector() {
        // md5("abc") — "a"+"b", empty secret; and "a"+"b" with secret "c".
        #expect(LastFMScrobbler.signature(["a": "b"], secret: "c")
            == "900150983cd24fb0d6963f7d28e17f72")
        #expect(LastFMScrobbler.signature(["a": "bc"], secret: "")
            == "900150983cd24fb0d6963f7d28e17f72")
    }

    @Test("format and callback are left out of the signature")
    func excludesFormat() {
        #expect(LastFMScrobbler.signature(["format": "json", "callback": "x"], secret: "")
            == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test("Signing is independent of dictionary order")
    func orderIndependent() {
        let a = LastFMScrobbler.signature(["z": "1", "a": "2", "m": "3"], secret: "s")
        let b = LastFMScrobbler.signature(["a": "2", "m": "3", "z": "1"], secret: "s")
        #expect(a == b)
    }
}
