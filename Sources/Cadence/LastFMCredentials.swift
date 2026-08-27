import Foundation

/// Last.fm API credentials, compiled in. Register an application at
/// <https://www.last.fm/api/account/create> to get a key and shared secret.
///
/// This repository is **public**, so real values must not be committed. Fill
/// them in locally and tell git to leave your copy alone:
///
/// ```
/// git update-index --skip-worktree Sources/Cadence/LastFMCredentials.swift
/// ```
///
/// With both fields empty, `isConfigured` is false and the Preferences window
/// shows scrobbling as unavailable rather than offering a flow that cannot
/// complete — a fresh clone still builds and runs.
enum LastFMCredentials {
    static let apiKey = ""
    static let sharedSecret = ""

    static var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }
}
