import Foundation
import Observation
import Security
import CadenceCore
import CadenceLibrary
import CadenceServer

/// Agent access, as Settings and the app see it: the switch, the MCP
/// endpoint's state, its key, and the last change an agent made.
///
/// **Off until asked**, like library sharing. Building a controller starts
/// nothing; a normal launch calls `resumeIfEnabled()` once, and the headless
/// modes never do, so none of them opens a port.
///
/// **This Mac's own library only.** The controller is built for a live
/// launch on the local store. Showing a paired Mac's library, or the preview
/// library, has no controller at all, so an agent can never write to a
/// library this Mac only borrows.
///
/// **A failed start switches it off**, for the reason `SharingController`
/// gives: a switch that reads on while nothing listens is a lie.
@MainActor
@Observable
final class AgentAccessController {

    enum Status: Equatable {
        case off
        case starting
        case on(port: UInt16)
    }

    struct Change: Equatable {
        var summary: String
        var date: Date
    }

    /// High enough to be clear of the ports development servers favour.
    static let defaultPort: UInt16 = 47474
    static let keychainService = "com.formgeist.cadence.agents"
    static let keychainAccount = "mcp-key"

    private(set) var isEnabled: Bool
    private(set) var status: Status = .off
    private(set) var lastError: String?
    /// The most recent edit an agent made, for Settings to show.
    private(set) var lastChange: Change?

    /// `http://127.0.0.1:<port>/mcp` while on.
    var endpointURL: String? {
        guard case .on(let port) = status else { return nil }
        return "http://127.0.0.1:\(port)\(MCPServer.path)"
    }

    private let library: SQLiteLibraryStore
    private weak var model: AppModel?
    private let settings: any SettingsStore
    private let keychain: any CadenceCore.KeychainStore
    private let port: UInt16?
    private let serverVersion: String
    private let now: @Sendable () -> Date

    private var listener: HTTPListener?
    /// The one task that starts and stops the listener, so a switch flipped
    /// twice quickly never runs a start and a stop at once.
    private var worker: Task<Void, Never>?
    /// Set when the key changes while on: the listener holds the old one
    /// and must be started again.
    private var needsRestart = false

    /// - Parameter port: Nil lets the system choose, for tests.
    init(library: SQLiteLibraryStore, model: AppModel, settings: any SettingsStore,
         keychain: any CadenceCore.KeychainStore,
         port: UInt16? = AgentAccessController.defaultPort,
         serverVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
         now: @escaping @Sendable () -> Date = Date.init) {
        self.library = library
        self.model = model
        self.settings = settings
        self.keychain = keychain
        self.port = port
        self.serverVersion = serverVersion
        self.now = now
        isEnabled = settings.bool(forKey: .agentAccessEnabled) ?? false
    }

    // MARK: - The switch

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        settings.set(enabled, forKey: .agentAccessEnabled)
        lastError = nil
        reconcile()
    }

    func resumeIfEnabled() {
        if isEnabled { reconcile() }
    }

    /// Waits for a start or stop in flight. For tests.
    func settle() async {
        await worker?.value
    }

    /// Stops the listener without changing the setting, for quitting.
    func shutDown() {
        listener?.stop()
        listener = nil
        status = .off
    }

    // MARK: - The key

    /// The key an agent sends as `Authorization: Bearer`. Made on first use
    /// and kept in the Keychain. Settings shows it on request; nothing writes
    /// it to a log or a file.
    func key() -> String {
        if let existing = keychain.string(forAccount: Self.keychainAccount), !existing.isEmpty {
            return existing
        }
        let made = Self.makeKey()
        keychain.set(made, forAccount: Self.keychainAccount)
        return made
    }

    /// Replaces the key. Every agent set up with the old one is refused from
    /// now on.
    func regenerateKey() {
        keychain.set(Self.makeKey(), forAccount: Self.keychainAccount)
        if status != .off {
            needsRestart = true
            reconcile()
        }
    }

    /// 256 bits from the system generator, base64url without padding.
    static func makeKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Running

    private func reconcile() {
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        defer { worker = nil }
        while true {
            if needsRestart, status != .off {
                needsRestart = false
                stopListener()
                continue
            }
            switch (isEnabled, status) {
            case (true, .off):
                status = .starting
                do {
                    let listener = try HTTPListener.mcp(server: makeServer(), port: port)
                    let bound = try await listener.start()
                    self.listener = listener
                    status = .on(port: bound)
                } catch {
                    stopListener()
                    isEnabled = false
                    settings.set(false, forKey: .agentAccessEnabled)
                    lastError = "Agent access could not start, and is off. "
                        + "Another app may be using port \(port.map(String.init) ?? "it needs")."
                }
            case (false, .on), (false, .starting):
                stopListener()
            default:
                return
            }
        }
    }

    private func stopListener() {
        listener?.stop()
        listener = nil
        status = .off
    }

    private func makeServer() -> MCPServer {
        let changes: @Sendable (LibraryChange) async -> Void = { [weak self] change in
            await self?.agentChanged(change)
        }
        let tools = MCPToolSet([
            LibraryTools(library: library, now: now),
            LibraryWriteTools(library: library, now: now, onChange: changes),
        ])
        return MCPServer(
            configuration: .init(serverVersion: serverVersion, instructions: LibraryTools.instructions),
            authenticator: FixedKeyAuthenticator(key: key()),
            tools: tools)
    }

    private func agentChanged(_ change: LibraryChange) async {
        lastChange = Change(summary: change.summary, date: now())
        var parts: AppModel.LibraryParts = []
        if change.parts.contains(.playlists) { parts.insert(.playlists) }
        if change.parts.contains(.folders) { parts.insert(.folders) }
        if change.parts.contains(.catalogs) { parts.insert(.catalogs) }
        if change.parts.contains(.memories) { parts.insert(.memories) }
        if change.parts.contains(.likes) { parts.insert(.likes) }
        await model?.applyChange(parts, notice: Self.notice(for: change.summary))
    }

    /// `Created the playlist “X”` becomes `An agent created the playlist “X”`.
    static func notice(for summary: String) -> String {
        guard let first = summary.first else { return "An agent changed the library" }
        return "An agent " + first.lowercased() + summary.dropFirst()
    }
}
