# Cadence

A native macOS FLAC player built with SwiftUI. Local library, real metadata,
gapless playback, and an interface that isn't a reskin of iTunes.

**Status:** it plays. Point it at a folder, and Cadence reads the tags, extracts
the artwork, builds a searchable SQLite library, and decodes it through
SFBAudioEngine with gapless transitions.

The build plan and open questions live in `PLAN.md`, which is kept
locally and deliberately not tracked in this repo.

```bash
make run                          # launch the app
make test                         # 131 tests
make app                          # assemble a signed, sandboxed Cadence.app
make audio-check                  # can a sandboxed build go bit-perfect?
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
only reach folders you granted through the picker. A restart is the bug PLAN.md §7 warns about; engine-driven
is what gapless looks like from the outside. Whether the seam is *audible*
still needs headphones.

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
anything. That call appears to succeed and produces silence, which is the
"silently stall" PLAN.md §6 rules out.

## Folder access

Folders are remembered as **app-scoped bookmarks**, not paths. Without them the
music folder becomes unreadable on the second launch of a sandboxed build and
there is no workaround — PLAN.md §5.

`SecurityScopedFolders` also handles the half of §7 that is easier to get
wrong: every `startAccessingSecurityScopedResource()` must be paired with a
stop, because leaked scopes eventually exhaust the kernel's limit and file
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

`make shots` renders twelve states — every screen, plus each awkward case above
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
| Traffic lights | three painted circles | reserved space | `.hiddenTitleBar` supplies real ones |
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

## Bundling without Xcode

There is no Xcode on this machine and therefore no `.xcodeproj` — but an `.app`
is a directory with a known shape, and [`Scripts/make-app.sh`](Scripts/make-app.sh)
assembles one: Info.plist, the resource bundles, the ten decoder frameworks,
and an ad-hoc signature with the sandbox entitlements from PLAN.md §5.

That matters more than convenience. A real bundle identity is what Now Playing,
media keys, the app sandbox, security-scoped bookmarks and window restoration
all require, so most of phase 5 is reachable without Xcode. `codesign`,
`notarytool` and `stapler` all ship with Command Line Tools, so even
notarization needs an Apple Developer account rather than an Xcode install.

One consequence to know about: SwiftPM's generated `Bundle.module` accessor
looks only beside the executable or at the `.app` root — never in
`Contents/Resources` — and calls `fatalError` when it finds nothing. `FontLoader`
resolves its own bundle instead, and degrades to system fonts rather than dying.

Also temporary: neither `Testing` nor `XCTest` is in the CLT SDK, so
swift-testing is an explicit package dependency scoped to the test target, and
`make test` passes the linker the path to `lib_TestingInterop.dylib`.

## Bit-perfect output

PLAN.md §3 calls the sandbox question the one that could reshape the release
plan: if a sandboxed build cannot set `kAudioDevicePropertyNominalSampleRate`,
the choice is direct distribution or the App Store without bit-perfect output.

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

## Licence

**MIT** — see [LICENSE](LICENSE). This settles the licence question and keeps
every option open, including relicensing later. The constraints that follow:
Cog is GPL, so read it for reference but never copy from it, and Chromaprint is
LGPL, so it is off the table for static linking if phase 6 wants acoustic
fingerprinting.

SFBAudioEngine pulls in three LGPL components — lame, mpg123 and musepack — and
they arrive as **dynamic** frameworks, which is what makes them compatible with
an MIT app. Two things follow at phase 7: embed them as frameworks rather than
merging them into the binary, and ship their licence texts. Statically linking
them would be the case PLAN.md §8 rules out.

Bundled fonts are licensed separately under the SIL Open Font License —
[Manrope](Sources/Cadence/Resources/OFL-Manrope.txt) and
[IBM Plex Mono](Sources/Cadence/Resources/OFL-IBMPlexMono.txt). OFL permits
bundling in a commercial or MIT-licensed application; it only requires that the
fonts themselves stay under OFL and are not sold on their own.
