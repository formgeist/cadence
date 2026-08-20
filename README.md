# Cadence

A native macOS FLAC player built with SwiftUI. Local library, real metadata,
gapless playback, and an interface that isn't a reskin of iTunes.

**Status:** the app runs. `CadenceCore` — models, protocol boundary,
`PlaybackController`, mock engine, preview library — is complete and tested, and
the full interface is built against it from the design canvas. No audio is
decoded and no database is opened yet: `MockPlayerEngine` advances a clock and
`InMemoryLibraryStore` serves `PreviewData`.

See [PLAN.md](PLAN.md) for the build plan and open questions.

```bash
make run     # launch the app
make test    # 48 tests, no third-party dependencies in the code under test
make shots   # render every screen to Snapshots/ for design review
```

## Layout

| Target | Dependencies | Contains |
|---|---|---|
| `CadenceCore` | none | models, protocols, `PlaybackController`, mock engine, preview data |
| `Cadence` | `CadenceCore` | the app — views, design tokens, snapshot tool |

`CadenceAudio` (SFBAudioEngine) and `CadenceLibrary` (GRDB) are not written yet.
The protocol boundary they will implement — `PlayerEngine`, `MetadataReader`,
`LibraryStore`, `ArtworkStore` — is in
[`Boundaries.swift`](Sources/CadenceCore/Protocols/Boundaries.swift), and the
composition root that will name them is
[`AppContainer`](Sources/Cadence/CadenceApp.swift). Swapping the real
implementations in is a change to those two lines and nothing above them.

`CadenceCore` has no third-party dependencies, so previews and design
prototypes can import it freely.

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
| Fonts | Manrope, IBM Plex Mono | system fallback until the files are bundled | see below |

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

Undecided — see PLAN.md §8. Make this call before the dependency list grows.
