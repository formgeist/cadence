# Offline downloads for the iOS app: build plan

Date: 2026-11-18. Branch: `claude/friendly-shannon-k1shs6` in `cadence`.

Let the iOS app keep songs from the paired Mac on the phone, so they play with
the Mac away. This is a handoff: step 1 is written but **has never been
compiled or tested** (it was written in a Linux container with no Swift
toolchain). Start by building it on a Mac.

## Why this design

The iOS app (`cadence-ios`) already downloads every track whole before
playing it. `RemoteTrackSource` (in `CadenceRemote`, this repository) shares
one download per song, writes to a partial file and renames it into place,
and retries when the Mac answers "busy". Browsing offline already works from
the metadata and artwork caches (`MacSession.browsingOffline`).

What is missing is keeping a track on purpose. The cache lives in Caches,
which iOS can empty, and it removes the least recently used files past a
2 GB budget. Downloaded songs stay the existing `RemoteSong` types, so the
screens and the player need no new data model.

Decided along the way:

- Kept songs live in **Application Support**, per paired Mac, **excluded from
  backup**, with **no budget**.
- `RemoteTrackSource` looks in the kept folder **before** the cache, so
  playback picks kept songs up without the app changing how it plays.
- Keeping **shares downloads with playback**. A song already in the cache is
  moved across, or copied (an APFS clone) if it was handed out recently and
  may be playing.
- The first version downloads **only while the app is open**. Background
  `URLSession` downloads come later (step 6).

## Step 1: the kept folder (written, needs building and tests)

Files:

- `Sources/CadenceRemote/RemoteDownloads.swift` (new). `RemoteDownloads` is
  a `Sendable` struct around a directory. Public API: `file(for:)`,
  `songIDs()`, `totalBytes()`, `remove(songID:)`, `removeAll()`. Internal:
  `existingFile(songID:suffix:)`, and `keep(_:songID:suffix:moving:)`, which
  creates the folder, sets `isExcludedFromBackup` and arrives through a
  hidden `.partial-…` file plus a rename.
- `Sources/CadenceRemote/RemoteTrackSource.swift` (changed):
  - New `init` parameter `downloads: RemoteDownloads? = nil`. Existing
    callers are unaffected.
  - `fileURL(for:)` returns the kept file when there is one. Otherwise it
    behaves as before. The download/wait code moved into a private
    `cached(songID:suffix:)`, which does not hand the file out.
  - New `public func keep(_ location: URL) async throws -> URL`.
  - `keeping: [String: Int]` stops `trim` removing a cached file that a
    `keep` is about to move.

### On the laptop

1. `git fetch origin claude/friendly-shannon-k1shs6 && git checkout claude/friendly-shannon-k1shs6`
2. `make build`, then fix whatever does not compile. Likely spots: the
   `defer` in `keep(_:)` mutating actor state, and `var folder` /
   `setResourceValues` in `RemoteDownloads.prepare()`.
3. Review two choices made blind:
   - `keep` wraps a file-system failure as
     `RemoteError.server(code: 0, message:)`. That is a stretch. Consider a
     new `RemoteError` case (for example `.storageFailed`, with a
     message), or letting the `CocoaError` through and documenting it.
   - `keep` on a source without a downloads folder is a `preconditionFailure`.
4. Add tests to `Tests/CadenceRemoteTests/RemoteLibraryTests.swift`, beside
   the `RemoteTrackSourceTests` suite, reusing `FakeDownloader`,
   `BusyDownloader` and `scratch(_:)`:
   - Keeping downloads once, and `fileURL(for:)` then returns the kept file
     (in the kept folder, not the cache) without a second download.
   - A song already in the cache is kept without downloading again, and is
     no longer in the cache (moved, because it was not handed out).
   - A song just handed out by `fileURL` is copied, not moved: both files
     exist.
   - Play and keep at the same time share one download (`held: true`, then
     `release()`, `started() == 1`).
   - Cancelling `keep` leaves nothing in the kept folder, hidden partials
     included (list with hidden files).
   - Kept songs survive the budget: tiny `budget`, keep one song, play
     several others, and the kept file is still there.
   - The `keeping` guard: with a tiny budget, a `keep` waiting on a held
     download while other songs finish still succeeds.
   - `RemoteDownloads`: `songIDs()`, `totalBytes()`, `remove(songID:)` (any
     suffix), `removeAll()`, and `isExcludedFromBackup` set on the folder.
   - `source.removeAll()` empties the cache but **not** the kept folder.
   - An invalid location throws `RemoteError.notFound`.
5. `make test` until green. Then commit, push and open a PR to `cadence`.

## Step 2: wire it into the iOS app (cadence-ios)

The iOS project takes `cadence` as a remote Swift package
(`XCRemoteSwiftPackageReference "cadence"` in `project.pbxproj`). Either
merge step 1 and update the package, or point Xcode at the local checkout
while developing.

- `CadenceiOS/Model/MacSession.swift`:
  - Create `RemoteDownloads(directory:)` under Application Support:
    `…/Application Support/Remote/<fingerprint prefix 16>/downloads`,
    mirroring `cacheRoot`'s naming.
  - Pass it to `RemoteTrackSource(…, downloads:)` and keep a reference
    (`let downloads: RemoteDownloads`).
  - `removeCaches()` (used by Forget Mac) must also call
    `downloads.removeAll()`. `clearDownloads()` and `downloadedBytes()`
    today mean the **cache**. Rename them to `clearCache` and `cachedBytes`,
    and add kept-download equivalents.
- `CadenceiOS/Shell/SettingsView.swift`: show storage as two lines,
  "Downloaded" and "Cache", each with its own clear action. Before Forget
  Mac, say how much downloaded music will be deleted.

## Step 3: the download queue (about 2 days)

A `@MainActor @Observable` model in cadence-ios, for example
`Model/Downloads.swift`, owned by `MacSession`:

- `download(album:)` and `download(playlist:)` queue the songs' locations
  (`RemoteTrackLocation.url(songID:suffix:)`).
- One or two `keep` calls at a time. The Mac limits concurrent downloads per
  device, and playback must not wait behind a long queue.
- Publish per-song state (queued, downloading, kept, failed), per-album
  progress, and a set of kept song ids (from `downloads.songIDs()`) for the
  views.
- Cancel per album, and cancel all. A failed song stays failed with a
  retry; it does not stop the rest of the queue.
- Pause while `MacSession.connection` is not `.connected`, and resume after.

## Step 4: keep the metadata (about 1 day)

A Downloaded screen has to work with the Mac away, even for albums never
opened offline. When an album or playlist is downloaded, store its decoded
`RemoteAlbum` or `RemotePlaylist` JSON beside the songs, for example
`downloads/albums/<id>.json`. The `RemoteMetadataCache` is a cache and can
be emptied, so it can't be relied on. Use the existing artwork cache, or
copy the cover in as well.

## Step 5: screens (about 2 days)

In `CadenceiOS/Library/`:

- A download button on album and playlist pages, showing progress, then
  "Downloaded" with a remove action.
- A small mark on track rows for kept songs.
- A **Downloaded** section: a tab on iPad's sidebar, and an entry under
  Library on iPhone. It reads the stored metadata from step 4.
- `ConnectionStateView.takesOver(session)` currently replaces the library
  when the Mac can't be reached. With downloads present, let the person go
  straight to Downloaded and play, without first choosing "browse offline".

## Step 6: later

- **Background downloads** with a background `URLSession`, so a large album
  finishes with the phone locked. The pinned-certificate check has to
  work in the background session's delegate. This is the main difference
  between 1 week and 2.
- **Reconcile with the Mac.** A track that moves on the Mac gets a new ID
  (see `docs/server-ios-recon.md`, section 2), which orphans its download.
  When connected, check kept ids against the library and offer to fetch
  any that changed.

## Estimate

About a week for steps 1–5 with downloads only while the app is open.
About 1½–2 weeks with background downloads.
