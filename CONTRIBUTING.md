# Contributing to Cadence

Cadence is a community-run project. Bug reports, fixes, and features are all
welcome. This document covers what you need to build it, the one architectural
rule the codebase is organised around, and how a change gets from your machine
into `main`.

## Building and testing

You need a Mac with the Xcode **Command Line Tools** — a full Xcode install is
not required and the project deliberately has no `.xcodeproj`.

```bash
make run      # launch the app
make test     # run every suite
make app      # assemble a signed, sandboxed Cadence.app
```

`make test` links against `swift-testing`, which ships inside Xcode's toolchain
but not the Command Line Tools SDK — the Makefile passes the linker the path to
`lib_TestingInterop.dylib` so `swift test` works anyway. Run tests through
`make test`, not `swift test` directly, or the link will fail.

Some behaviour only exists with a real bundle identity — Now Playing, media
keys, the app sandbox, security-scoped bookmarks, window restoration. Verify
those with `make app` and the assembled bundle, not `make run`.

### Last.fm credentials

Working on scrobbling needs a Last.fm API key and shared secret
([register an app](https://www.last.fm/api/account/create)). This repository is
public, so put them in `Sources/Cadence/LastFMCredentials.swift` and tell git to
ignore your copy:

```bash
git update-index --skip-worktree Sources/Cadence/LastFMCredentials.swift
```

With the fields left empty the app still builds and runs; the Preferences window
just shows scrobbling as unavailable.

## The layering rule

Cadence is four targets, and the dependency direction is the design:

| Target | May depend on | Contains |
|---|---|---|
| `CadenceCore` | **nothing third-party** | models, protocols, `PlaybackController`, mock engine, preview data |
| `CadenceLibrary` | GRDB | SQLite store, FTS5 search, FLAC tag reader, import scanner, artwork cache |
| `CadenceAudio` | SFBAudioEngine | decode, gapless, metadata for every non-FLAC format |
| `Cadence` | all three | the app — views, design tokens, snapshot and diagnostic tools |

Two things follow that a change must not break:

- **`CadenceCore` stays free of third-party dependencies.** Previews and design
  prototypes import it directly; a dependency added here forfeits that. The
  `swift-testing` package is the one exception, scoped to the test targets only.
- **Nothing above [`Boundaries.swift`](Sources/CadenceCore/Protocols/Boundaries.swift)
  knows SFBAudioEngine exists.** Audio reaches the rest of the app through
  protocols; only the composition root names the concrete engine, in one line.
  If you find yourself wanting to `import SFBAudioEngine` outside `CadenceAudio`,
  the boundary needs a new protocol method instead.

## Diagnostic tools

The app doubles as its own test harness. These need the unsandboxed build
(`swift run`), since the bundled app can only reach folders granted through the
picker:

```bash
make a11y                          # print the real accessibility tree, flag silent controls
make bench [TRACKS=30000]          # measure the store and scrolling against a synthetic library
make audio-check                   # can a sandboxed build set the output sample rate?
make shots                         # render every screen to Snapshots/ for design review
make scan FOLDER=~/Music/FLAC      # import a folder and print what was found
swift run Cadence --play ~/Music/FLAC/Some/Album   # verify audio and the gapless handshake
```

If your change touches list rendering, run `make bench` before and after and put
the numbers in the PR. If it touches a control, run `make a11y` and check the
control still announces itself. The README's Performance and Accessibility
sections explain what these measure and the ways of measuring them that are
wrong.

## Commits and pull requests

- **Branch off `main`.** Name the branch for the change (`fix-mute-restore`,
  `folder-removal`), not the issue number.
- **Write commit subjects as imperative statements of the change** — "Persist
  the queue and playback position across launches", not "queue persistence" or
  "fixed bug". Keep the subject under ~70 characters; use the body to explain
  *why*, not *what*.
- **Keep a PR to one concern.** Two unrelated fixes are two PRs.
- **Fill in the pull request template.** The test-plan checklist is not
  optional — say what you ran (`make test`, `make bench`, a manual check in the
  running app) and what you saw. If a suite is red on `main` before your change,
  say so.
- **Link the issue** with `Fixes #123` so it closes on merge.
- New behaviour needs a test. Bug fixes need a test that fails without the fix —
  mention that you verified it fails.
- If your change makes a claim in the README wrong, update the README in the
  same PR.

[CI](.github/workflows/ci.yml) runs `swift test` and a release build on every
push and pull request, on a macOS runner with full Xcode. Green CI plus a
maintainer review is the bar for merge; `make test` passing locally is how you
get there without waiting on the runner.

## Good first issues

Issues tagged
[`good first issue`](https://github.com/formgeist/cadence/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22)
are scoped, self-contained, and carry enough context in the issue body to start
without reading the whole codebase. Comment on one to claim it.

## Licence

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE) that covers the project.
