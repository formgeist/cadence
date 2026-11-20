import Foundation

/// Tells whether the paired Mac's library has changed since it was last
/// asked, from the revision the Mac reports with `ping`.
///
/// The first check only records a revision: there is nothing to compare it
/// with. A Mac too old to report one never counts as changed.
public actor LibraryRevisionWatcher {

    public typealias Fetch = @Sendable () async throws -> Int64?

    private let fetch: Fetch
    private var known: Int64?

    public init(fetch: @escaping Fetch) {
        self.fetch = fetch
    }

    public init(client: RemoteLibraryClient) {
        self.init(fetch: { try await client.libraryRevision() })
    }

    /// True when the revision differs from the one the last check saw.
    public func check() async throws -> Bool {
        guard let revision = try await fetch() else { return false }
        defer { known = revision }
        guard let known else { return false }
        return known != revision
    }

    /// Forgets the revision seen, so the next check records one afresh. For
    /// when the library is about to be read for another reason, such as the
    /// Mac answering again.
    public func reset() {
        known = nil
    }
}
