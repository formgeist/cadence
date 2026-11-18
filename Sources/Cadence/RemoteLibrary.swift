import AppKit
import Foundation
import Observation
import Security
import CadenceCore
import CadenceLibrary
import CadenceRemote

// MARK: - Which library

/// Whether the app shows this Mac's library or the paired Mac's.
///
/// One library at a time. Everything the app builds at launch, from the
/// store to Now Playing and the folder watcher, is built for one of them, so
/// switching relaunches the app rather than rebuilding it in place.
enum LibraryChoice: String {
    case thisMac
    case pairedMac

    private static let key = "Cadence.librarySource"

    /// The choice as stored. A choice of the paired Mac with no pairing to
    /// go with it reads as this Mac.
    static func current(defaults: UserDefaults = .standard,
                        pairing: PairedMacStore = PairedMacStore()) -> (LibraryChoice, RemoteCredentials?) {
        guard defaults.string(forKey: key) == pairedMac.rawValue,
              let credentials = pairing.load() else { return (.thisMac, nil) }
        return (.pairedMac, credentials)
    }

    static func set(_ choice: LibraryChoice, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: key)
    }
}

// MARK: - The pairing

/// Keeps the pairing with another Mac in the keychain: the server, its
/// pinned fingerprint, and this Mac's API key.
///
/// The key is the whole of this Mac's access to the other library, so it is
/// never written to preferences or a file. "This device only", so a
/// Migration Assistant copy of this Mac does not carry it to another one.
/// One paired Mac at a time: pairing again replaces it.
struct PairedMacStore: Sendable {
    var service = "com.formgeist.cadence.pairing"
    var account = "paired-mac"

    func load() -> RemoteCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(RemoteCredentials.self, from: data)
    }

    func save(_ credentials: RemoteCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    enum StoreError: Error, LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            "The pairing could not be saved in the keychain."
        }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

// MARK: - Settings kept apart

/// Settings with the library's own state kept apart from the rest.
///
/// Volume, scrobbling and sort orders are the listener's, and follow them
/// from one library to the other. The queue, the recents and the selected
/// tab are about one library's tracks, so the paired Mac's are kept under
/// their own keys: switching back to this Mac finds its own queue where it
/// was left. So is the sharing switch, so this Mac never tries to share a
/// library it is not showing.
@MainActor
final class PerLibrarySettingsStore: SettingsStore {
    static let perLibraryKeys: Set<SettingsKey> = [
        .queueTrackIDs, .queueOrderedTrackIDs, .queueCurrentTrackID, .queuePosition,
        .queuePlaylistOrigin, .recentSearches, .recentlyPlayed, .recentPlays,
        .collapsedPlaylistFolders, .tab, .librarySharingEnabled,
    ]

    private let shared: any SettingsStore
    private let library: any SettingsStore

    init(shared: any SettingsStore, library: any SettingsStore) {
        self.shared = shared
        self.library = library
    }

    private func store(_ key: SettingsKey) -> any SettingsStore {
        Self.perLibraryKeys.contains(key) ? library : shared
    }

    func double(forKey key: SettingsKey) -> Double? { store(key).double(forKey: key) }
    func set(_ value: Double?, forKey key: SettingsKey) { store(key).set(value, forKey: key) }
    func bool(forKey key: SettingsKey) -> Bool? { store(key).bool(forKey: key) }
    func set(_ value: Bool?, forKey key: SettingsKey) { store(key).set(value, forKey: key) }
    func string(forKey key: SettingsKey) -> String? { store(key).string(forKey: key) }
    func set(_ value: String?, forKey key: SettingsKey) { store(key).set(value, forKey: key) }
}

// MARK: - A session with the paired Mac

/// Everything that belongs to the paired Mac while the app shows its
/// library: the client, its caches, and whether the Mac can be reached.
@MainActor
@Observable
final class RemoteLibrarySession {

    let credentials: RemoteCredentials
    let client: RemoteLibraryClient
    let library: RemoteLibraryStore
    let artwork: RemoteArtworkStore
    /// Downloads tracks for the engine, and has the connection checked when
    /// one fails.
    let tracks: any TrackSource
    private let downloads: RemoteTrackSource
    /// Listening history and Last.fm answers, kept on this Mac in a database
    /// of their own, since the paired library cannot hold them. Memories are
    /// not offered for a paired library; see `AppModel.visibleTabs`.
    let history: SQLiteLibraryStore
    private(set) var connection: RemoteConnection.State = .idle

    /// Called when the Mac answers again after not answering, so the app
    /// can load what it could not while the Mac was away.
    var onReconnected: (() -> Void)?

    private let monitor: RemoteConnection
    private let cacheRoot: URL
    private var watcher: Task<Void, Never>?

    var macName: String { credentials.server.name }

    init(credentials: RemoteCredentials) throws {
        self.credentials = credentials
        let folder = Self.folderName(for: credentials)
        // Caches, because the system may empty it when space runs short:
        // nothing here is anything a second download cannot replace.
        cacheRoot = try FileManager.default
            .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Cadence/Remote/\(folder)", isDirectory: true)
        client = RemoteLibraryClient(
            credentials: credentials,
            cache: RemoteMetadataCache(directory: cacheRoot.appendingPathComponent("metadata")))
        library = RemoteLibraryStore(client: client)
        artwork = RemoteArtworkStore(client: client,
                                     directory: cacheRoot.appendingPathComponent("artwork"))
        downloads = RemoteTrackSource(downloader: client,
                                      directory: cacheRoot.appendingPathComponent("tracks"))
        // Application Support, beside this Mac's own library: history is not
        // a cache, and should outlive one being emptied.
        let historyURL = try SQLiteLibraryStore.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("Remote/\(folder)", isDirectory: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        history = try SQLiteLibraryStore(url: historyURL.appendingPathComponent("history.sqlite"))
        let monitor = RemoteConnection(client: client)
        self.monitor = monitor
        tracks = CheckingTrackSource(downloads: downloads, monitor: monitor)
    }

    /// A folder per Mac, named by its certificate, so two paired Macs over
    /// time never share caches.
    private static func folderName(for credentials: RemoteCredentials) -> String {
        String(credentials.server.fingerprint.prefix(16))
    }

    func start() {
        let monitor = monitor
        watcher = Task { [weak self] in
            var wasAway = false
            for await state in await monitor.states() {
                guard let self else { return }
                self.connection = state
                switch state {
                case .connected:
                    if wasAway { self.onReconnected?() }
                    wasAway = false
                case .offline, .unreachable, .needsAttention:
                    wasAway = true
                case .idle, .connecting:
                    break
                }
            }
        }
        Task { await monitor.start() }
    }

    func retry() {
        let monitor = monitor
        Task { await monitor.retryNow() }
    }

    /// A request failed; the connection decides whether that means the Mac
    /// has gone.
    func report(_ error: RemoteError) {
        let monitor = monitor
        Task { await monitor.connectionLost(error) }
    }

    /// Removes everything kept for this Mac: caches and history.
    static func removeEverything(for credentials: RemoteCredentials) {
        let folder = folderName(for: credentials)
        let manager = FileManager.default
        if let caches = try? manager.url(for: .cachesDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: false) {
            try? manager.removeItem(at: caches.appendingPathComponent("Cadence/Remote/\(folder)"))
        }
        if let support = try? SQLiteLibraryStore.defaultURL().deletingLastPathComponent() {
            try? manager.removeItem(at: support.appendingPathComponent("Remote/\(folder)"))
        }
        UserDefaultsSettingsStore.removeAll(prefix: RemoteLibrarySession.settingsPrefix)
    }

    /// Where the paired library's own settings are kept.
    static let settingsPrefix = "Cadence.PairedMac."
}

extension UserDefaultsSettingsStore {
    /// Forgets every setting under `prefix`.
    static func removeAll(prefix: String, defaults: UserDefaults = .standard) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}

/// A failed download is often the first sign the Mac has gone to sleep.
/// This has the connection look, so the title bar says so rather than
/// still claiming to be connected.
private struct CheckingTrackSource: TrackSource {
    let downloads: RemoteTrackSource
    let monitor: RemoteConnection

    func fileURL(for location: URL) async throws -> URL {
        do {
            return try await downloads.fileURL(for: location)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The source reports failures as playback errors, so the cause
            // is not known here. The check finds out: a Mac that answers
            // stays connected.
            await monitor.connectionLost(.unreachable)
            throw error
        }
    }
}

// MARK: - Choosing and pairing, for Preferences

/// What Preferences shows and does about the library: which one is open,
/// the paired Mac, pairing with one, and switching.
@MainActor
@Observable
final class LibrarySourceController {

    enum PairingState: Equatable {
        case idle
        case pairing(macName: String)
        case failed(String)
    }

    /// The library the app is showing now.
    let active: LibraryChoice
    /// The session when the paired Mac's library is showing.
    let session: RemoteLibrarySession?
    private(set) var pairedMacName: String?
    private(set) var pairingState: PairingState = .idle
    /// A pairing link that arrived while Preferences was not on screen, to
    /// be confirmed there.
    var pendingLink: PairingPayload?

    /// Nil in preview and headless runs, which must not touch the keychain:
    /// a read there can stop at a password prompt nobody is looking at.
    private let store: PairedMacStore?
    private let relaunch: @MainActor () -> Void

    init(active: LibraryChoice, session: RemoteLibrarySession?,
         store: PairedMacStore?,
         relaunch: @escaping @MainActor () -> Void = LibrarySourceController.relaunchApp) {
        self.active = active
        self.session = session
        self.store = store
        self.relaunch = relaunch
        pairedMacName = session?.macName ?? store?.load()?.server.name
    }

    var isShowingPairedMac: Bool { active == .pairedMac }

    /// Reads a pasted or opened link. Throws a sentence for the listener.
    static func payload(from text: String) throws -> PairingPayload {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else { throw LinkError.notALink }
        do {
            return try PairingPayload(url: url)
        } catch PairingPayload.ParseError.unsupportedVersion {
            throw LinkError.newerVersion
        } catch {
            throw LinkError.notALink
        }
    }

    enum LinkError: Error, LocalizedError {
        case notALink, newerVersion
        var errorDescription: String? {
            switch self {
            case .notALink:
                "That is not a Cadence pairing link. On the other Mac, open Preferences › Sharing, "
                    + "show a code, and copy its link."
            case .newerVersion:
                "That link is from a newer Cadence. Update this Mac to pair with it."
            }
        }
    }

    /// Pairs with the Mac in the link, keeps the pairing, and switches to
    /// its library. A pairing this Mac already had is replaced.
    func pair(_ payload: PairingPayload) async {
        guard let store else { return }
        pairingState = .pairing(macName: payload.name)
        do {
            let credentials = try await RemotePairing.pair(payload, deviceName: Self.deviceName)
            if let previous = store.load(), previous.server.fingerprint != credentials.server.fingerprint {
                RemoteLibrarySession.removeEverything(for: previous)
            }
            try store.save(credentials)
            pairedMacName = credentials.server.name
            pairingState = .idle
            use(.pairedMac)
        } catch let error as RemoteError {
            pairingState = .failed(Self.pairingMessage(error))
        } catch {
            pairingState = .failed(error.localizedDescription)
        }
    }

    func dismissFailure() { pairingState = .idle }

    /// A pairing link opened from outside the app. Held for Preferences to
    /// confirm; anything else is reported there.
    func open(_ url: URL) {
        do {
            pendingLink = try Self.payload(from: url.absoluteString)
            pairingState = .idle
        } catch {
            pairingState = .failed(error.localizedDescription)
        }
    }

    /// Switches library, which relaunches the app. Nothing happens when the
    /// choice is the one showing.
    func use(_ choice: LibraryChoice) {
        guard choice != active else { return }
        LibraryChoice.set(choice)
        relaunch()
    }

    /// Forgets the paired Mac: the key, the caches and the history kept for
    /// it. The other Mac still lists this one until it is removed there.
    func forget() {
        guard let store, let credentials = store.load() else { return }
        store.delete()
        RemoteLibrarySession.removeEverything(for: credentials)
        pairedMacName = nil
        if active == .pairedMac {
            LibraryChoice.set(.thisMac)
            relaunch()
        }
    }

    private static func pairingMessage(_ error: RemoteError) -> String {
        switch error {
        case .unreachable, .offline:
            "The other Mac did not answer. Check that it is awake, on the same network, "
                + "and that sharing is on in Cadence there."
        case .pairingRefused:
            "The other Mac did not accept this link. It may have expired or been used. "
                + "Show a new code there and copy its link again."
        case .untrustedServer:
            "Something answered at that address, but it is not the Mac in the link. "
                + "Nothing was sent to it."
        default:
            error.message
        }
    }

    /// How this Mac appears in the other Mac's list of paired devices.
    static var deviceName: String {
        Host.current().localizedName ?? "Mac"
    }

    /// Opens a new copy of the app and quits this one, so the new one is
    /// built for the library just chosen. An app run outside its bundle, as
    /// `swift run` runs it, has nothing to reopen: it quits, and says so.
    static func relaunchApp() {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else {
            let alert = NSAlert()
            alert.messageText = "Open Cadence again to switch library"
            alert.informativeText = "This copy of Cadence is not an app bundle, so it cannot reopen itself."
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
