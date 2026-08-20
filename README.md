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
make test                         # 110 tests
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
rendering and whether the move to the second track was engine-driven or a
controller restart. A restart is the bug PLAN.md §7 warns about; engine-driven
is what gapless looks like from the outside. Whether the seam is *audible*
still needs headphones.

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

## Toolchain note

This machine has Command Line Tools rather than a full Xcode, which means no
`.xcodeproj` and no `xcodebuild`. Two consequences, both temporary:

- The app is an SPM executable, not an `.app` bundle. `AppDelegate` sets the
  activation policy by hand so it gets a Dock icon and a key window.
- Neither `Testing` nor `XCTest` is in the SDK, so swift-testing is an explicit
  package dependency, scoped to the test target only. `make test` passes the
  linker the path to `lib_TestingInterop.dylib`.

Both disappear once Xcode is installed and the app target of PLAN.md §5 exists.

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
