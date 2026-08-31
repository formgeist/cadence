# Cadence

[![CI](https://github.com/formgeist/cadence/actions/workflows/ci.yml/badge.svg)](https://github.com/formgeist/cadence/actions/workflows/ci.yml)

A native macOS FLAC player built with SwiftUI. Local library, real metadata,
gapless playback, and an interface that isn't a reskin of iTunes.

**Status:** it plays. Point it at a folder, and Cadence reads the tags, extracts
the artwork, builds a searchable SQLite library, and decodes it through
SFBAudioEngine with gapless transitions.

Remaining work is tracked as [issues](https://github.com/formgeist/cadence/issues),
grouped into the Phase 6 (Depth) and Phase 7 (Release) milestones.

```bash
make run                          # launch the app
make test                         # 235 tests
make app                          # assemble a signed, sandboxed Cadence.app
make audio-check                  # can a sandboxed build go bit-perfect?
make a11y                         # print the accessibility tree
make bench                        # store and scrolling benchmarks
make shots                        # render every screen to Snapshots/
make scan FOLDER=~/Music/FLAC     # import a folder and print what was found
```

## Layout

| Target | Dependencies | Contains |
|---|---|---|
| `CadenceCore` | none | models, protocols, `PlaybackController`, mock engine, preview data |
| `CadenceLibrary` | GRDB | SQLite store, FTS5 search, FLAC tag reader, import scanner, artwork cache |
| `CadenceAudio` | SFBAudioEngine | decode, gapless, metadata for every other format |
| `Cadence` | all three | the app — views, design tokens, snapshot and diagnostic tools |

`CadenceCore` has no third-party dependencies, so previews and design
prototypes can import it freely. Nothing above
[`Boundaries.swift`](Sources/CadenceCore/Protocols/Boundaries.swift) knows SFB
exists; the composition root names it in one line.

### Formats

FLAC goes to the pure-Swift reader in `CadenceLibrary`, which needs no audio
library and is what let import ship before the audio layer existed. Everything
else SFB decodes — ALAC, AIFF, WAV, MP3, AAC, Opus, Vorbis, WavPack, Monkey's
Audio — goes to `SFBMetadataReader`. `MetadataRouter` composes the two.

### What Cadence does not decode

**DSD (`.dsf`, `.dff`) and any hi-res path beyond PCM FLAC are out of scope for
the first release** — a documented Phase 7 non-goal, tracked in
[#96](https://github.com/formgeist/cadence/issues/96). SFBAudioEngine can open a
DSD stream, but bit-perfect DSD needs DSD-over-PCM packing or a native-DSD
device path, and both rest on the exclusive device access and sample-rate
switching that are
[probed but not implemented](https://github.com/formgeist/cadence/issues/34)
and [not yet re-verified on a real DAC](https://github.com/formgeist/cadence/issues/12).
Listing DSD as a supported format while silently resampling it to 88.2 kHz
would be worse than not listing it at all.

### Diagnostics

```bash
swift run Cadence --play ~/Music/FLAC/Some/Album   # verify audio and gapless
swift run Cadence --fonts                          # verify bundled faces
```

`--play` starts near the end of the first track and reports whether frames are
rendering, whether the move to the second track was engine-driven or a
controller restart, and what was published to Now Playing.

It prefers the library's copy of each track, which carries the artworkID the
scanner assigned. Reading the file directly gives correct tags but no artwork
reference — a harness that only did that would report a gap the app does not
have, and would have missed the artwork crash above.

Diagnostics need the unsandboxed build (`swift run`), since the bundled app can
only reach folders you granted through the picker. A restart means the handshake
failed; engine-driven is what gapless looks like from the outside. Whether the
seam is *audible* still needs headphones.

## System integration

`NowPlayingCoordinator` publishes to `MPNowPlayingInfoCenter` and accepts
`MPRemoteCommandCenter` commands, which is what makes the media keys, Control
Center, the Now Playing widget and the AirPods stem work. It observes the
controller rather than being called by it, so nothing about system integration
leaks into playback.

All of it needs a real bundle identity — run `make app`, not `make run`.

Two things worth knowing:

- The artwork request handler is `nonisolated` and closes over `Data`, not an
  `NSImage`. MediaPlayer invokes it on its own queue while serialising the Now
  Playing dictionary, so a handler formed in a main-actor context carries an
  isolation check that fails there and traps the process. Every track with cover
  art crashed the app until this was fixed.
- Elapsed time is not republished on a timer. The system extrapolates from the
  playback rate and the last known position, and republishing every tick makes
  the Control Center scrubber stutter.

### When the output device goes away

Unplugging headphones mid-track **pauses** and keeps the position, rather than
continuing out of the speakers. The engine reports the loss as its own event
rather than an error, because the track is still perfectly good — only the
destination changed.

Pressing play afterwards hands the file to the engine again and seeks back,
rather than calling `resume()` on a graph that is no longer connected to
anything. That call appears to succeed and produces silence, which is the silent
stall that losing a device must never produce.

### Scrobbling

`ScrobbleController` observes playback the same way `NowPlayingCoordinator`
does — nothing about Last.fm reaches `PlaybackController`. It sends a "now
playing" update when a track starts and scrobbles once the track passes
Last.fm's threshold (half its length, or four minutes, whichever is sooner;
never under 30 seconds). Paused time and seeks don't count toward it.

A scrobble that can't be sent is held in a queue persisted through
`SettingsStore` and retried on the next success, on a timer, and at launch.
The session key lives in the keychain; enable it and sign in from
**Preferences** (`⌘,`). Off by default. It lives in `CadenceCore` behind a
`Scrobbler` protocol so a second target — ListenBrainz — fits the same shape.

## Accessibility

```bash
swift run Cadence --a11y
```

Prints the real accessibility tree for each screen — the one an assistive client
sees, queried through `AXUIElement` — and flags any control that would announce
nothing. Writing accessibility modifiers is easy; reading back what they
actually produced is the only way to know. Three things it caught that looked
fine in source:

- SwiftUI's elements are not `NSView`s. Walking `subviews` finds AppKit's scroll
  views and nothing of the app, which reported thirty unlabelled elements and
  none of the real ones.
- The scrubber and volume slider reached the tree with role `AXUnknown` —
  named, but with no indication of what they were. Custom-drawn controls need
  `.accessibilityRepresentation` to arrive as real sliders.
- SF Symbol names leak: the mute button announced itself as "Volume High" and
  repeat as "Repeat 1".

Rows are single stops rather than four. A track reads as *"Track 2, Slow Hours,
five minutes thirty-eight seconds, FLAC, 24 bit, 96 kilohertz"* — durations and
sample rates are spelled out, because "5:38" read aloud is ambiguous and
"16/44.1" is nonsense. Artwork is hidden where a row already names the album.

## Performance

```bash
make bench
```

Generates a synthetic library and measures the store and scrolling. This
settles the list-performance question, though not as it was posed — it asked
whether SwiftUI `Table` stays smooth at library size, and the design uses
`LazyVGrid` and `LazyVStack`, never `Table`.

At 30,000 tracks both grids hold the display's frame rate: 8.3 ms median with
artwork, across 250 artists and 2,500 albums alike. p95 is 24 ms and about a
quarter of frames run long, which is artwork decodes landing mid-scroll rather
than layout. No `NSCollectionView` bridge needed.

Scrolling is measured on a visible window with a display link. Two ways of
measuring it are wrong, and both looked plausible:

- `cacheDisplay(in:to:)` rasterises on the CPU, where blur costs orders of
  magnitude more than on the GPU. Measured that way a drop shadow looks like a
  1.6-second frame.
- Scrolling each list in a **fixed number of steps** makes a long list travel
  proportionally faster. At 180 steps the album grid moved 638pt per frame
  against the artists grid's 42pt and reported 49 ms — a fling no trackpad
  produces — while the same grid measured at the same 40pt per step sits at
  8.3 ms. It read as a real 2,500-album regression and sent the harness's own
  verdict to "needs an `NSCollectionView` bridge". The step is a fixed
  *distance* now; velocity is what has to be held constant for two lists, or
  one list across a change, to be comparable at all.

## Folder access

Folders are remembered as **app-scoped bookmarks**, not paths. Without them the
music folder becomes unreadable on the second launch of a sandboxed build and
there is no workaround.

`SecurityScopedFolders` also handles the half that is easier to get wrong:
every `startAccessingSecurityScopedResource()` must be paired with a stop,
because leaked scopes eventually exhaust the kernel's limit and file
access starts failing in ways that look like corruption. Access is therefore
handed out as a token whose lifetime *is* the access — there is no unpaired
call to forget. Bookmarks that go stale are re-made in place, so a folder that
moves keeps working; bookmarks that cannot resolve at all are dropped rather
than retried on every launch.

Folders are bookmarked rather than individual files: access to a folder extends
to its contents, so one scope covers a whole library.

## Importing

`⌘O` in the app, or from the command line:

```bash
swift run Cadence --scan ~/Music/FLAC            # into the real library
swift run Cadence --scan ~/Music --library /tmp/scratch.sqlite --tracks
```

The scanner skips files whose size and mtime are unchanged, parses with bounded
parallelism, and writes in batched transactions. Re-importing a path updates
that row and keeps its id, so playlists pointing at it survive a rescan. A file
that fails to parse is reported and the import continues.

**Preferences ▸ Library** lists the folders that have been added, and removes
one. Removing a folder drops its bookmark and takes every track the library
held from inside it — out of playlists too, through the same cascade as any
other library removal. The files on disk are never touched.

Tags are read directly rather than through an audio library — FLAC's metadata
blocks are simple enough that import works before the audio layer compiles,
which is what the protocol boundary is for. Other formats wait for
`SFBMetadataReader`.

### What the parsers forgive

Metadata in the wild breaks the spec constantly. Each of these is handled, with
a test:

- `TRACKNUMBER=3/12`, `DISCNUMBER=1/3` — index and total in one field
- `DATE=1969-08-15`, `DATE=1969/08` — a year wearing a date's clothes
- Repeated `ARTIST` fields — joined, not silently dropped
- `REPLAYGAIN_TRACK_GAIN=-6.40 dB` — the unit is part of the value
- Tags that aren't valid UTF-8 — falls back to Latin-1 rather than losing them
- Leading and trailing whitespace — `" Korn"` and `"Korn"` are otherwise two artists
- `COMPILATION=1` on a deluxe edition by one band — believed only when the
  track artists back it up
- `Kid A (1)` / `Kid A (2)` with matching `DISCNUMBER` — one album, two discs,
  not two albums
- Missing or zero `STREAMINFO` values — no division by zero, no NaN durations

## Playlists

A playlist is rows in `playlistItem`, ordered by `position` and addressed by
row id rather than track id — the same track may sit in a playlist twice, and
then a track id names two rows. Removing and reordering therefore take
*offsets*, which is also the shape `onDelete` and `onMove` hand over.

Names are deliberately not unique, so every operation addresses a playlist by
id. `replacePlaylists` still exists for import, where rewriting the whole set
in one transaction is the right thing; nothing the interface does goes through
it, because editing one playlist should not rewrite the others.

Tracks get in three ways: the Add to Playlist submenu on album cards, album
track rows and playlist rows; the album header's `+`; and dragging either onto
a playlist row in the sidebar or on the Playlists shelf. Creating a playlist
from one of those menus seeds it with the tracks the menu was opened on.

Two things worth knowing:

- Rows in the playlist screen are not `.draggable`. `onMove` brings its own
  drag, and a row carrying both hands the reorder gesture to the wrong one —
  you go to move a track up two places and start dragging it at the sidebar
  instead. Sending a track elsewhere is the context menu's job.
- Deleting a track from the library removes it from every playlist, because
  `playlistItem.trackID` cascades. That is what lets the playlist screen treat
  a row offset and a stored position as the same number.

## Building UI before the audio layer works

`MockPlayerEngine` advances a clock instead of decoding, and fakes the gapless
handshake: hand it a prepared track and it reports `advancedToNext` when the
clock runs out, exercising the same controller path real playback will.

`PreviewData` supplies a deliberately awkward library — a 59-minute
single-track album, a three-disc box set, a Various Artists compilation, albums
with no artwork, classical tracks where the composer outranks the performer, a
remaster that must not merge with its original, and a title long enough to wrap
three lines at 46pt.

```swift
#Preview {
    RootView()
        .environment(PreviewData.controller())
}
```

## Design review

`make shots` renders sixteen states — every screen, plus each awkward case above
— to PNGs without opening a window:

```bash
swift run Cadence --snapshot ~/Desktop/cadence-shots
```

It renders through a real off-screen `NSWindow`, not `ImageRenderer`, which
never lays out `ScrollView` content and silently produced blank lists.

The design canvas the interface was built from is
[Cadence.dc.html](https://claude.ai/design/p/af59472b-17be-4420-b17e-19a438189905?file=Cadence.dc.html).
Its values live in
[`Tokens.swift`](Sources/Cadence/DesignSystem/Tokens.swift); views reference
tokens, never literals.

### Where the app departs from the canvas

| | Canvas | App | Why |
|---|---|---|---|
| Traffic lights | three painted circles | reserved space | the window supplies real ones; the header is the title bar, so `WindowChrome` runs the content under it and re-centres the lights against the search field |
| Track row | click plays | double click plays, single click selects | a click while reading down a track list should not restart the music |
| Artist row | — | opens the artist's whole discography | one album per artist left the rest unreachable |
| Library header | sticky, blurred | fixed above the scroll view | same appearance, no blurred layer pinned over a fast list |
| Track subtitle | artist under every title | only on compilations, composer for classical | redundant on a single-artist album, essential on a compilation |
| Album metadata | one line | wraps to two | a box set adds "3 discs" and overflowed |

## Fonts

The design specifies **Manrope** and **IBM Plex Mono**, both OFL. Drop the
`.ttf` files into `Sources/Cadence/Resources/` and they are registered at
launch; until then every call falls back to the system face at the same size
and weight, and the app logs one line saying so.

Expected filenames: `Manrope-Regular`, `Manrope-Medium`, `Manrope-SemiBold`,
`Manrope-Bold`, `Manrope-ExtraBold`, `IBMPlexMono-Regular`,
`IBMPlexMono-Medium`.

## App icon

A red grooved disc on a black squircle. The source is the `.iconset` in
[`Icon/`](Icon/README.md) — ten PNGs from 16 to 1024 — and `make app` runs
`iconutil` over it, writing `AppIcon.icns` into the bundle and pointing
`CFBundleIconFile` at it.

`.icns` rather than an asset catalog for the same reason there is no
`.xcodeproj`: catalogs are compiled by `actool`, which is Xcode's, while
`iconutil` ships with Command Line Tools. Nothing is lost at this stage —
catalogs matter for App Store submission and for the macOS 26 appearance
variants, neither of which is in reach yet.

The icon only appears in the bundled app. `make run` launches the SwiftPM
executable, which has no bundle and so takes the generic placeholder in the
Dock; check the icon with `make app` and Finder.

## Bundling without Xcode

There is no Xcode on this machine and therefore no `.xcodeproj` — but an `.app`
is a directory with a known shape, and [`Scripts/make-app.sh`](Scripts/make-app.sh)
assembles one: Info.plist, the resource bundles, the icon, the ten decoder
frameworks, and an ad-hoc signature with the sandbox entitlements.

That matters more than convenience. A real bundle identity is what Now Playing,
media keys, the app sandbox, security-scoped bookmarks and window restoration
all require, so most of phase 5 is reachable without Xcode. `codesign`,
`notarytool` and `stapler` all ship with Command Line Tools, so even
notarization needs an Apple Developer account rather than an Xcode install.

One consequence to know about: SwiftPM's generated `Bundle.module` accessor
looks only beside the executable or at the `.app` root — never in
`Contents/Resources` — and calls `fatalError` when it finds nothing. `FontLoader`
resolves its own bundle instead, and degrades to system fonts rather than dying.

Another: `keychain-access-groups` is validated against the signature's team
identifier, which an ad-hoc signature does not have. Current macOS does not
treat an unvalidatable access group as a soft keychain failure — it kills the
process at spawn (`Launchd job spawn failed`). So the ad-hoc bundle ships
without that entitlement and the scrobble key uses the app's own default access
group; the team-prefixed group comes back with a Developer ID build (issue #8).

Also temporary: neither `Testing` nor `XCTest` is in the CLT SDK, so
swift-testing is an explicit package dependency scoped to the test targets, and
`make test` passes the linker the path to `lib_TestingInterop.dylib`. CI runs on
a full-Xcode runner where that path does not exist, so
[`ci.yml`](.github/workflows/ci.yml) calls `swift test` directly and skips the
Makefile.

## Bit-perfect output

The sandbox question is the one that could reshape the release plan: if a
sandboxed build cannot set `kAudioDevicePropertyNominalSampleRate`, the choice
is direct distribution or the App Store without bit-perfect output.

**It can.** A sandboxed, signed build switches the output device rate and it
takes effect:

```
device:     MacBook Pro Speakers
sandboxed:  yes
available:  44100, 48000, 88200, 96000
set rate:   OK (switched, restored)
```

The check verifies the device actually *reports* the new rate rather than
trusting the setter's return value — `AudioObjectSetPropertyData` returns
`noErr` for a request that has merely been accepted, and coreaudiod applies it
asynchronously.

Two caveats before this settles the release plan: it was tested on built-in
speakers with an ad-hoc signature, so it is worth re-running against an external
DAC — which is where bit-perfect actually matters — and under a Developer ID
build.

## Contributing

Cadence is community-run. [`CONTRIBUTING.md`](CONTRIBUTING.md) covers building
and testing, the target-layering rule the codebase is organised around, the
diagnostic tools, and how a change gets reviewed and merged. Issues tagged
[`good first issue`](https://github.com/formgeist/cadence/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
are scoped and carry enough context to start from the issue alone.

## Licence

**MIT** — see [LICENSE](LICENSE). This settles the licence question and keeps
every option open, including relicensing later. The constraints that follow:
Cog is GPL, so read it for reference but never copy from it, and Chromaprint is
LGPL, so it is off the table for static linking if phase 6 wants acoustic
fingerprinting.

SFBAudioEngine pulls in four LGPL components — **lame** (LGPL v2),
**mpg123** and **libsndfile** (LGPL v2.1), and **tta** (LGPL v3). They arrive as
**dynamic** frameworks, which is what makes them compatible with an MIT app;
statically linking any of them would forfeit that. Musepack is *not* among them,
despite a long-standing claim here that it was: only its encoder is LGPL, and
the half Cadence uses — the `libmpcdec` decoder — is BSD. The remaining bundled
decoders (FLAC, Ogg, Vorbis, Opus, WavPack, Musepack) are BSD, which asks that
their notices be reproduced in what ships beside the binary.

Both halves of that obligation are now met. `make-app.sh` embeds each component
as a framework, and copies every licence text into
`Cadence.app/Contents/Resources/Licences`. The texts and the full component
table live in [Licences/](Licences/README.md).

Bundled fonts are licensed separately under the SIL Open Font License —
[Manrope](Sources/Cadence/Resources/OFL-Manrope.txt) and
[IBM Plex Mono](Sources/Cadence/Resources/OFL-IBMPlexMono.txt). OFL permits
bundling in a commercial or MIT-licensed application; it only requires that the
fonts themselves stay under OFL and are not sold on their own. Both texts ship
in the bundle with the rest.
