# Cadence — a native macOS FLAC player

> Working name; rename freely. Every identifier is prefixed `Cadence`, so a
> project-wide find-and-replace is all it takes.

**The thesis:** the open-source options for FLAC on macOS are functional but
dated. Cog works and is well-maintained, but it's an AppKit app from another
era of Mac design. The commercial options that look good — Doppler, Swinsian —
are closed and paid. The gap is a *well-designed* open-source native player.
Design is the product here; everything below exists to get out of its way.

**The strategy that follows from that:** don't build an audio engine. Take
SFBAudioEngine for decode, gapless, and metadata, put a protocol boundary in
front of it, and spend the saved time on the interface.

---

## 1. Current state of this repo

A Swift package with three targets. The audio and library layers are scaffolded
against real dependencies; the app target does not exist yet.

```
Cadence/
├── Package.swift
├── Sources/
│   ├── CadenceCore/            ← no dependencies. Safe to import anywhere.
│   │   ├── Models/Library.swift          Track, Album, Artist, Artwork, AudioFormat
│   │   ├── Playback/PlaybackState.swift  state machine, progress, modes, errors
│   │   ├── Playback/PlaybackController.swift  @Observable, the UI's single entry point
│   │   ├── Protocols/Boundaries.swift    PlayerEngine, MetadataReader, LibraryStore, ArtworkStore
│   │   └── Preview/PreviewSupport.swift  MockPlayerEngine + PreviewData
│   ├── CadenceAudio/           ← SFBAudioEngine
│   │   ├── SFBPlayerEngine.swift         PlayerEngine impl + sample-rate switching
│   │   └── SFBMetadataReader.swift       MetadataReader impl + forgiving parsers
│   └── CadenceLibrary/         ← GRDB
│       ├── Migrations.swift              schema, FTS5, pragmas
│       ├── SQLiteLibraryStore.swift      upsert + search implemented, rest TODO
│       └── LibraryScanner.swift          concurrent import, batched writes
└── Tests/
    └── CadenceCoreTests/       identity, formatting, controller behaviour
```

### What is genuinely done

- The protocol boundary (`PlayerEngine`, `MetadataReader`, `LibraryStore`,
  `ArtworkStore`) — the shape of the app.
- `PlaybackController` — queue, shuffle, repeat, ReplayGain resolution, gapless
  handshake, bookmark resolution. This is the object every view binds to.
- `MockPlayerEngine` + `PreviewData` — a fully working fake so UI can be built
  and demoed with zero audio code. **Use this for all design work.**
- Database schema including the FTS5 search index and the WAL pragmas.
- The import scanner: fingerprint diffing, bounded-parallelism parsing,
  batched transactions.

### What is deliberately unfinished

- **Every `fatalError("TODO")` in `SQLiteLibraryStore`** — the remaining query
  methods. They all follow the same shape as `tracks(matching:)`.
- **FTS row population.** `upsert` writes `track` but not the denormalised
  `trackSearch` columns. Search returns nothing until this is done.
- **`ArtworkStore` has no implementation.** Needs hashing, disk cache,
  thumbnail generation.
- **The app target.** No Xcode project, no views, no `@main`.
- **The SFB adapters are written against a remembered API surface.** See §3.

---

## 2. First session for Claude Code

In order. Do not skip step 1.

1. **`swift build`.** It will fail. SFBAudioEngine's Swift API has shifted
   across versions, and the adapter files were written from memory. Fix
   `SFBPlayerEngine.swift` and `SFBMetadataReader.swift` against the actual
   headers in `.build/checkouts/SFBAudioEngine/`. The protocol boundary means
   corrections stay in those two files — nothing above them changes.
2. **`swift test`.** `CadenceCoreTests` has no third-party dependencies and
   should pass once the package resolves.
3. **Implement `ArtworkStore`** (SHA-256 content addressing, cache directory,
   `CGImageSourceCreateThumbnailAtIndex` for thumbnails).
4. **Finish `SQLiteLibraryStore`** — the TODO methods plus FTS population.
5. **Write an integration test** that scans a fixture folder of real FLAC files
   and asserts on the resulting library. This is the highest-value test in the
   project; everything downstream depends on import being correct.
6. **Create the Xcode app target** and wire the dependency graph (§5).

---

## 3. Known unknowns — verify these early

Four things that could invalidate parts of the plan. Test them in the first
week, not the last.

| Question | Why it matters | How to settle it |
|---|---|---|
| Does the SFB API match the adapters? | Blocks all playback | `swift build`, read the headers |
| Can a **sandboxed** build set `kAudioDevicePropertyNominalSampleRate`? | Decides App Store vs. direct distribution | Sandboxed test build, call `matchOutputSampleRate`, check the OSStatus |
| Does SFB's gapless actually work on your files? | It's the main reason for the dependency | Enqueue two tracks from a live album, listen at the seam |
| Does SwiftUI `Table` stay smooth at your library size? | Decides whether you need an `NSTableView` bridge | Generate 30k synthetic rows, scroll, profile |

The sandbox question is the one that can reshape the release plan, so answer it
first. If sample-rate switching is denied under the sandbox, the options are:
ship direct-only with Sparkle, or ship to the App Store without bit-perfect
output and treat it as a known limitation.

---

## 4. Architecture

```
        ┌──────────────────────────────────────────┐
        │  SwiftUI views  ·  design system         │
        └──────────────────┬───────────────────────┘
                           │  observes
        ┌──────────────────▼───────────────────────┐
        │  PlaybackController  ·  LibraryViewModel │   @MainActor @Observable
        └────────┬──────────────────────┬──────────┘
                 │                      │
        ┌────────▼─────────┐   ┌────────▼──────────┐
        │  PlayerEngine    │   │  LibraryStore     │   ← protocols (CadenceCore)
        └────────┬─────────┘   └────────┬──────────┘
                 │                      │
        ┌────────▼─────────┐   ┌────────▼──────────┐
        │ SFBPlayerEngine  │   │ SQLiteLibraryStore│   ← implementations
        │ MockPlayerEngine │   │ GRDB + FTS5       │
        └──────────────────┘   └───────────────────┘
```

Three rules that keep this honest:

1. **The engine never sees the database.** It takes URLs. This is what makes
   `MockPlayerEngine` possible and what makes swapping SFB out cheap.
2. **The UI never sees an implementation type.** Views take
   `PlaybackController` and `any LibraryStore`, never `SFBPlayerEngine`.
3. **Position updates are a separate stream from state changes.** Progress
   fires ~10×/second; if it shared a channel with play/pause the whole view
   tree would invalidate ten times a second.

---

## 5. Xcode project setup

SPM alone can't produce a `.app`. Structure:

```
Cadence.xcodeproj
└── Cadence (macOS app target)
    ├── depends on → Cadence package (local, added via "Add Local…")
    ├── CadenceApp.swift          @main, dependency container
    ├── Views/
    ├── DesignSystem/
    └── Cadence.entitlements
```

Entitlements to start with:

```xml
<key>com.apple.security.app-sandbox</key>              <true/>
<key>com.apple.security.files.user-selected.read-only</key> <true/>
<key>com.apple.security.files.bookmarks.app-scope</key> <true/>
```

That last one is not optional. Without app-scoped bookmarks the user's music
folder becomes inaccessible on the second launch, and there is no workaround —
`Track.bookmark` exists for exactly this reason.

Composition root:

```swift
@main
struct CadenceApp: App {
    @State private var container = AppContainer()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(container.playback)
                .environment(container.library)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { CadenceCommands() }

        Settings { SettingsView() }
    }
}
```

---

## 6. Build phases

### Phase 1 — Foundations (make it build)
Steps 1–5 of §2. Deliverable: `swift test` green, and a command-line harness
that scans a folder and prints the resulting library.

### Phase 2 — Skeleton app
`NavigationSplitView`: sidebar (Library / Albums / Artists / Playlists /
Genres), content pane, persistent now-playing bar. Folder picker that grants
and persists a security-scoped bookmark. Import with visible progress and a
working cancel button. Deliverable: your own library visible in the app.

**Do not design this screen yet** — build it plain. Design comes in phase 4
once you know what the real content looks like at real volume.

### Phase 3 — Playback
Play/pause/next/previous, seek by scrubbing, volume, queue view with drag
reorder, shuffle and repeat, ReplayGain mode switching. Verify gapless at a
live-album seam. Deliverable: an app you'd actually use for listening.

### Phase 4 — Design pass
The reason for the project. Rebuild the phase-2 views against the mocks.
Budget real time here — this is not polish applied at the end, it is the
feature.

Translate the mocks into a token layer *before* touching any screen:

```swift
enum Tokens {
    enum Space { static let xs = 4.0; static let s = 8.0; static let m = 16.0 /* … */ }
    enum Radius { static let control = 6.0; static let card = 10.0 }
    enum Font { static let display: SwiftUI.Font = …; static let body: … }
    enum Palette { static let surface: Color = …; static let accent: Color = … }
}
```

Views reference tokens, never literals. When the design shifts — and it will,
once you see it against a real library — one file changes.

Check every layout against `PreviewData`, which is stocked with the content
that breaks naive designs: a 59-minute single-track album, an album title long
enough to wrap three lines, a three-disc box set needing disc grouping, albums
with no artwork, classical tracks where composer matters more than artist, and
a Various Artists compilation. Mocks drawn against tidy metadata tend to fall
apart on first contact with a real collection.

### Phase 5 — System integration
`MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` (Control Center, media
keys, AirPods), menu bar commands with shortcuts, dock menu, window state
restoration, and — importantly — graceful handling of the output device
disappearing mid-playback. Unplugging headphones must not crash or silently
stall.

### Phase 6 — Depth
Smart playlists, gapless verification across the whole library, artwork
fetching for albums with none, folder watching via `FSEvents` for automatic
rescan, ReplayGain computation with libebur128 for untagged files, keyboard
navigation throughout.

### Phase 7 — Release
Developer ID signing, notarization, Sparkle appcast, a real README with
screenshots, and a licence decision (§8).

---

## 7. Implementation notes worth having in advance

**Gapless is a handshake, not a feature flag.** `PlaybackController` calls
`prepareNext` the moment a track *starts*, not near its end. SFB then transitions
by itself and reports it; the controller follows via the `wantsNextTrack` stream
rather than driving the transition. Getting this backwards produces a gap.

**Artwork will destroy your scroll performance if loaded naively.** A 200-album
grid loading full-resolution JPEGs is hundreds of megabytes and visible
stutter. Always `CGImageSourceCreateThumbnailAtIndex` with
`kCGImageSourceThumbnailMaxPixelSize`, cache by `(artworkID, size)`, and hold
an `NSCache` in front of the disk cache.

**Album identity is `(albumArtist, title, year)`.** Already encoded in
`Album.Key`. Title alone merges every *Greatest Hits*; adding year keeps
remasters separate from originals.

**Metadata in the wild violates the spec constantly.** `TRACKNUMBER=3/12`,
multiple `ARTIST` fields, `DATE=1969-08-15`, missing `STREAMINFO` values, tags
in the wrong text encoding. `SFBMetadataReader` has forgiving parsers for the
common cases — add to them rather than to the importer, and add a test each
time.

**Sandbox + bookmarks or nothing.** Resolve `Track.bookmark`, call
`startAccessingSecurityScopedResource()`, and pair every start with a stop.
Leaking scoped resources eventually exhausts the kernel's limit and file access
starts failing in ways that look like corruption.

---

## 8. Licence decision — make it now

It constrains what you can use, so decide before writing more code.

**MIT / BSD / Apache only** keeps every option open, including relicensing or
going closed later. SFBAudioEngine (MIT) and GRDB (MIT) are both fine.
Constraint: Cog is GPL, so read it for reference but never copy from it, and
Chromaprint (LGPL) is off the table for static linking.

**GPL** loosens everything — port from Cog directly, use whatever you like,
stop thinking about it — at the cost of forcing derivatives to stay open. Given
the project exists because no good open-source option does, that's a defensible
and arguably fitting choice.

Current dependency licences:

| Dependency | Licence | Notes |
|---|---|---|
| SFBAudioEngine | MIT | decode, gapless, metadata |
| GRDB.swift | MIT | store, FTS5 |
| Sparkle | MIT | phase 7, direct distribution only |
| libebur128 | MIT | phase 6, optional |
| Chromaprint | LGPL | phase 6, optional — check before adopting |
| Cog | GPL | reference only, never copy |

Verify each at its repository before shipping; licences do occasionally change.

---

## 9. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| Sandbox blocks sample-rate switching | Reshapes distribution plan | Test in week 1 (§3) |
| SFB API drift | Blocks the build | Isolated to two files by the protocol boundary |
| SwiftUI list performance at 30k rows | Janky core screen | Bridge `NSTableView` for that one view |
| Gapless doesn't work on your files | Loses the main reason for SFB | Test at a live-album seam early |
| Design phase gets squeezed | Kills the whole premise | It's phase 4, with its own budget — not end-stage polish |
| Metadata edge cases | Wrong library, hard to debug | Fixture corpus + a test per surprise |

---

## 10. Commands

```bash
swift build                 # resolve and compile all three targets
swift test                  # CadenceCoreTests needs no dependencies
swift package resolve       # pin versions
swift package update        # bump within the declared ranges

# Read the real SFB API when the adapters don't compile
ls .build/checkouts/SFBAudioEngine/Sources
```
