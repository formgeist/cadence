import Foundation
import CoreServices

/// Watches one folder for filesystem changes via FSEvents.
///
/// FSEvents is coalesced and reports per *directory*, not per file — this type
/// only tells a caller "something changed under here, as of this event ID."
/// The fingerprint diff in `LibraryScanner.scan` still does the real work of
/// figuring out what, so the callback doesn't parse or forward paths at all.
///
/// One stream per folder, not one multi-path stream: starting or stopping a
/// watch for a single folder stays independent of every other one, the same
/// shape `SecurityScopedFolders.beginAccess`/`forget` already use per URL.
@MainActor
public final class FolderEventStream {
    public typealias EventID = FSEventStreamEventId

    // Touched under MainActor isolation everywhere except `deinit`, which by
    // definition runs with no other reference left to race against — hence
    // `nonisolated(unsafe)` rather than fighting Sendable checking there for
    // a raw C pointer that carries no actual concurrent-access risk.
    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let onChange: (EventID) -> Void

    /// `since` replays events that happened while nothing was watching — e.g.
    /// the app was closed — instead of forcing a full rescan on next launch.
    /// `nil` means "only from now on," used the first time a folder is watched.
    public init(url: URL, since: EventID?, latency: TimeInterval = 1.0,
                onChange: @escaping (EventID) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, numEvents, _, _, eventIds in
                // Non-capturing: `self` travels through `info`, not a closure
                // capture, since @convention(c) forbids the latter.
                // FSEventStreamSetDispatchQueue below hardcodes delivery to
                // .main, so assumeIsolated bridges what the compiler can't
                // see statically, without a Task hop per event.
                guard let info else { return }
                MainActor.assumeIsolated {
                    let watcher = Unmanaged<FolderEventStream>
                        .fromOpaque(info).takeUnretainedValue()
                    var latest: EventID = 0
                    for i in 0..<numEvents { latest = max(latest, eventIds[i]) }
                    watcher.onChange(latest)
                }
            },
            &context, [url.path] as CFArray,
            since ?? EventID(kFSEventStreamEventIdSinceNow),
            latency, 0)
        else { return }

        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        FSEventStreamStart(created)
    }

    /// Idempotent. Used explicitly when a folder is forgotten; `deinit`
    /// inlines the same calls rather than invoking this, since an isolated
    /// method can't be called from a deinit that isn't guaranteed to run on
    /// the actor.
    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
