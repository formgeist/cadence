import AppKit
import AuthenticationServices
import Observation
import CadenceCore

/// Turns a Spotify playlist into a Cadence playlist of the same songs, taken
/// from the library. Songs the library does not have are skipped.
///
/// Owns the Spotify sign-in too: `ASWebAuthenticationSession` shows Spotify's
/// consent page and hands back the `cadence://spotify-callback` redirect, so
/// no URL scheme has to be registered and no local server has to listen. The
/// token pair lives in the keychain, under its own service.
@MainActor @Observable
final class SpotifyImporter {
    enum State: Equatable {
        case idle
        case signingIn
        case importing
        case failed(String)
    }

    static let redirectURI = "cadence://spotify-callback"
    private static let keychainAccount = "Spotify"

    private let api: SpotifyAPI
    private let keychain: any CadenceCore.KeychainStore
    private let presenter = PresentationAnchor()

    private(set) var state: State = .idle
    private(set) var isSignedIn: Bool

    init(api: SpotifyAPI, keychain: any CadenceCore.KeychainStore) {
        self.api = api
        self.keychain = keychain
        isSignedIn = keychain.string(forAccount: Self.keychainAccount) != nil
    }

    var isConfigured: Bool { api.isConfigured }

    // MARK: Sign-in

    func connect() async {
        guard api.isConfigured else { state = .failed(SpotifyError.notConfigured.localizedDescription); return }
        state = .signingIn
        let authorization = api.beginAuthorization()
        do {
            let callback = try await webSignIn(authorization.url)
            let code = try SpotifyAPI.authorizationCode(from: callback,
                                                        expectedState: authorization.state)
            let token = try await api.exchange(code: code, verifier: authorization.verifier)
            store(token)
            state = .idle
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// A failure from last time should not greet the next attempt.
    func clearFailure() {
        if case .failed = state { state = .idle }
    }

    func signOut() {
        store(nil)
        state = .idle
    }

    private func webSignIn(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url, callbackURLScheme: "cadence"
            ) { callback, error in
                if let callback {
                    continuation.resume(returning: callback)
                } else {
                    continuation.resume(throwing: error ?? SpotifyError.malformedResponse)
                }
            }
            session.presentationContextProvider = presenter
            session.start()
        }
    }

    // MARK: Importing

    /// Reads the playlist, matches it against the library, and creates the
    /// playlist with whatever matched. Returns whether the sheet can close.
    func importPlaylist(from link: String, into model: AppModel) async -> Bool {
        guard let id = SpotifyAPI.playlistID(from: link) else {
            state = .failed(SpotifyError.invalidLink.localizedDescription)
            return false
        }
        state = .importing
        do {
            let playlist = try await withFreshToken { try await self.api.playlist(id: id, token: $0) }
            let result = PlaylistMatcher(library: model.allTracks).match(playlist.tracks)
            state = .idle
            await model.importPlaylist(named: playlist.name, matched: result.matched,
                                       total: playlist.tracks.count)
            return true
        } catch {
            if (error as? SpotifyError) == .signedOut { store(nil) }
            state = .failed(error.localizedDescription)
            return false
        }
    }

    /// Refreshes an expired access token first, and once more if Spotify
    /// turns down one that looked fresh.
    private func withFreshToken<T>(_ body: (SpotifyToken) async throws -> T) async throws -> T {
        guard var token = storedToken() else { throw SpotifyError.signedOut }
        if token.isExpired() {
            token = try await api.refresh(token)
            store(token)
        }
        do {
            return try await body(token)
        } catch SpotifyError.signedOut {
            token = try await api.refresh(token)
            store(token)
            return try await body(token)
        }
    }

    // MARK: Keychain

    private func storedToken() -> SpotifyToken? {
        guard let json = keychain.string(forAccount: Self.keychainAccount) else { return nil }
        return try? JSONDecoder().decode(SpotifyToken.self, from: Data(json.utf8))
    }

    private func store(_ token: SpotifyToken?) {
        let json = token
            .flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        keychain.set(json, forAccount: Self.keychainAccount)
        isSignedIn = json != nil
    }
}

/// The window Spotify's sign-in sheet attaches to.
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}
