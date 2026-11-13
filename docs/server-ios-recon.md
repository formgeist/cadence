# Library server and iOS client: Phase 0 recon

Date: 2026-11-13. Checked against `main` at `7792b52`.

This note records what the repository and its dependencies actually look like,
measured against the assumptions in the build plan
([Cadence: Library Server and iOS Client — Build Plan](https://claude.ai/artifact/7RrMFwXewhxpTnXNQBip3U)).
No feature code was written in this phase.

## Summary

| Plan assumption | Status |
|---|---|
| CadenceCore can build for iOS after isolating macOS-only code | **Confirmed, and easier than assumed**: it already type-checks for iOS with no changes |
| Track IDs survive rescans | **Confirmed** |
| Track IDs survive folder moves | **Changed**: they do not |
| Artists and albums have IDs to expose | **Changed**: neither has a stored ID |
| SFBAudioEngine builds for iOS | **Likely, not verified here** (see section 3) |
| SFBAudioEngine can be built without the LGPL decoders | **Changed**: not through SwiftPM as published; needs a fork |
| SFBAudioEngine can read a custom authenticated, pinned-TLS stream | **Changed**: no public way to supply a custom input source |
| Cadence's FLAC reader is reusable on iOS | **Confirmed**, but the iOS client does not need it |
| AVFoundation is a workable fallback | **Confirmed** for the common formats, with limits |
| HTTP and TLS can be done without a new dependency | **Confirmed**: Network.framework, with two small pieces of our own code |
| Design tokens can be extracted into a platform-neutral product | **Confirmed**: AppKit use in `Tokens.swift` is limited to font lookups |

Three findings need a decision before Phase 1 starts. They are listed under
[Decisions needed](#decisions-needed).

## 1. Package layout and macOS-only code

`Package.swift` declares `platforms: [.macOS(.v14)]` only, with four targets:
`CadenceCore`, `CadenceLibrary`, `CadenceAudio` and the `Cadence` executable.
Three are already exported as library products.

**CadenceCore** imports only `Foundation`, `Observation` and `CryptoKit`. All
three exist on iOS. Type-checking every CadenceCore source file against the
iOS 27.2 simulator SDK (`-target arm64-apple-ios26.0-simulator`, Swift 6
language mode) passes with zero errors. Making it build for iOS is therefore
only a matter of adding `.iOS(.v26)` to `platforms`; there is no macOS-only
code to isolate.

**CadenceLibrary** has two macOS-only files:

| File | macOS-only API |
|---|---|
| `FolderEventStream.swift` | FSEvents (`CoreServices`) |
| `SecurityScopedFolders.swift` | `.withSecurityScope` bookmark options |

The rest (`ImageIO`, `UniformTypeIdentifiers`, `CryptoKit`, GRDB) is available
on iOS. This does not matter for the first release: the iOS app has no local
library, and CadenceServer is macOS-only, so CadenceLibrary can stay macOS-only.

**CadenceAudio** has macOS-only code that the plan does not mention:
`OutputDevice.swift` and `OutputRateMatcher.swift` use the Core Audio HAL
(`AudioObjectGetPropertyData`, `kAudioHardwarePropertyDefaultOutputDevice`),
which does not exist on iOS. `SFBPlayerEngine` holds an `OutputRateMatcher`.
If the iOS app is to reuse `SFBPlayerEngine`, that code needs `#if os(macOS)`
isolation and CadenceAudio needs to become an iOS product. The plan lists only
CadenceCore, CadenceRemote and CadenceDesign as shared products, so this is an
open point (decision 3).

**Design tokens.** `Sources/Cadence/DesignSystem/Tokens.swift` imports AppKit
but uses it only for `NSFont` lookups (system-font fallback names, and checks
that Manrope and IBM Plex Mono are registered). Replacing those with
`#if canImport(AppKit)` / `UIKit` conditionals is straightforward.

**Toolchain.** Xcode 27.2 is installed and selected, with the iOS 27.2
simulator SDK. The comments in `Package.swift` and the `Makefile` that say
this machine has Command Line Tools only are now out of date; the
`swift-testing` package dependency and `TESTING_LIB` linker flags can probably
go, as a separate clean-up.

**Tags.** The repository has no git tags yet. The Phase 1 tag will be the first.

## 2. How tracks, albums and artists are identified

**Tracks** have a real, stored ID: `track.id`, a UUID string and the primary
key. `track.url` is a second unique key.

- *Rescans: stable.* `SQLiteLibraryStore.upsert` looks up the existing row by
  `url` and keeps its `id`. A forced re-read of every file keeps IDs too.
- *Moves and renames: not stable.* When a file moves, the scanner sees a new
  path (a new row with a new UUID) and a missing path (the old row is deleted).
  The delete cascades to `playlistItem` and `likedTrack`, so today a moved
  folder also silently drops those tracks from playlists and Liked Songs.
  Nothing matches the new file to the old row. The `fingerprint` column is
  size plus modification time, used only to skip unchanged files.

**Albums** have no stored ID. An album is an aggregate identified by
`Album.Key` (album artist, title, year), computed from track rows.

**Artists** have no stored ID either. `Artist.id` is the artist name.

**Playlists** have a stored UUID.

Other data (`playLog`, `memory`) is deliberately keyed by names so that it
survives rescans and moves.

### What this means for Phase 1

- Track IDs can go on the wire as they are. The UUID is already opaque.
- Album and artist IDs must be created. Proposal: derive them from the
  existing identity, as a truncated SHA-256 of the normalised key with a type
  prefix (`al-…`, `ar-…`). They are stable across rescans by construction and
  need no destructive schema change. They change when tags change, which is
  correct, because the album or artist is then a different one. The server
  needs a lookup from ID back to key; an indexed table filled at upsert is the
  simplest way, added by a non-destructive migration.
- Move survival needs new scanner behaviour: before deleting missing rows,
  match each new file against them (same fingerprint and same title, album,
  track number and duration) and update `url` in place, keeping the `id`.
  This also fixes the existing loss of playlist entries and likes on a move,
  so it is worth a pull request of its own, with tests.

## 3. Audio on iOS

### SFBAudioEngine

Cadence pins SFBAudioEngine `0.13.0`; upstream is at `0.15.0`. Both were read.

**iOS support.** The manifest declares `.iOS(.v15)`, and every binary
dependency ships `ios-arm64` and `ios-arm64_x86_64-simulator` slices. Upstream
maintains an iOS sample app. An actual iOS build could not be run in this
session, so "builds for iOS" is likely but unverified. It will be verified
when the Xcode project is created in Phase 1.

**LGPL decoders cannot be left out as published.** The package has one target,
`CSFBAudioEngine`, which depends unconditionally on all five LGPL packages:
`lame`, `mpc`, `mpg123`, `sndfile` and `tta-cpp`. There are no package traits,
build flags or separate products in `0.13.0` or `0.15.0`. A SwiftPM client
cannot switch them off. The plan's "built without the LGPL decoders" therefore
requires a fork whose manifest drops those five packages and excludes the
sources that use them:

- Decoders: `SFBMPEGDecoder`, `SFBLibsndfileDecoder`, `SFBMusepackDecoder`,
  `SFBTrueAudioDecoder`
- Encoders: `SFBMP3Encoder`, `SFBLibsndfileEncoder`, `SFBMusepackEncoder`,
  `SFBTrueAudioEncoder`

Decoders register themselves in `+load`, so excluding the files should be
enough; no central registry needs editing. MP3 would then be decoded by
`SFBCoreAudioDecoder` (Apple's decoder) instead of mpg123. FLAC, ALAC, AAC,
WAV, AIFF, Ogg Vorbis, Opus, WavPack and Monkey's Audio are unaffected.

For context: upstream ships the LGPL libraries as dynamic frameworks and
states that this is what keeps the default build LGPL-compatible. Whether
dynamically linked LGPL frameworks are acceptable in an App Store app is a
licensing judgement, not a technical one (decision 1).

**No custom input source.** `SFBInputSource` is a closed class cluster: `init`
is unavailable, the designated initialiser is in a private header, and the
only concrete sources are file, memory-mapped file, file-contents and in-memory
data. There is no HTTP source and no supported way to write one outside the
library. The file source reads the file length once, at open, so it cannot
play a file that is still being downloaded.

The workable design is: download the track with `URLSession` (which handles
the API key and the pinned certificate), write it to a cache file, and hand
SFBAudioEngine a file URL. This fits the plan's existing "pre-buffer the next
track to disk". The cost is a delay before the first track starts: about one
to two seconds for a 40 MB CD-quality FLAC album track on good Wi-Fi, more for
hi-res files. Later tracks are pre-buffered and start without a gap.

This shapes the `TrackSource` protocol in Phase 1: it should resolve
asynchronously to a local file URL (immediately for a local track, after a
download for a remote one), not expose a stream.

### FLAC reader

`FLACMetadataReader` imports only Foundation and CadenceCore, so it would
compile on iOS. It lives in CadenceLibrary, though, and the iOS client gets
all metadata from the server, so the first release does not need it.

### AVFoundation fallback

AVFoundation decodes FLAC, ALAC, AAC, MP3, WAV and AIFF natively. It does not
decode Ogg Vorbis, Ogg Opus, WavPack or Monkey's Audio, so those tracks would
be unplayable on iOS under the fallback. Gapless playback is achievable with
`AVAudioEngine` and scheduled files, less reliably with `AVQueuePlayer`. It
would use the same download-to-disk approach. It remains a sound fallback.

## 4. HTTP and TLS approach

**Choice: Network.framework directly, no new dependency.**

| Piece | Approach |
|---|---|
| Listener | `NWListener` with TLS parameters; the debug-only localhost listener uses the same code without TLS |
| TLS identity | A P-256 key and self-signed certificate generated at first enable, stored in the keychain, loaded as a `SecIdentity` |
| HTTP | A small HTTP/1.1 request parser of our own: `GET` and `HEAD` only, strict limits, `Range` support |
| Bonjour | `NWListener.service` |
| Client | `URLSession` with a trust-challenge delegate that compares the certificate's SHA-256 with the paired fingerprint |

Why not a dependency: the realistic alternative is Hummingbird or Vapor on
SwiftNIO with swift-nio-ssl and swift-certificates. That is a large dependency
tree, including BoringSSL, for a server that answers fifteen read-only `GET`
endpoints. The API surface we need is small enough that the request parser is
a few hundred lines, and owning it makes the limits in the security
requirements (header size, connection count, bounds-checked ranges) explicit
and directly fuzzable.

Costs of this choice, stated plainly:

- Apple has no API to create a certificate, so we write a minimal X.509 DER
  encoder (about 150 lines) and sign with the Security framework. It needs
  careful tests, including a round trip through `SecCertificateCreateWithData`.
- We own an HTTP parser on an untrusted network. The plan already requires
  fuzz and malformed-request tests; they become essential, not optional.

**Sandbox.** `Scripts/make-app.sh` grants `com.apple.security.network.client`
only. Phase 3 must add `com.apple.security.network.server`, and nothing else.

**Metadata cache on iOS** (the plan asks Phase 0 to choose storage): cache the
decoded browse responses as files in the app's Caches directory, keyed by
endpoint and parameters, and keep an in-memory index for local filtering.
Search goes to the server (`search3`). This keeps GRDB out of CadenceRemote.
If browsing a 30,000-track library proves slow in Phase 4, revisit.

## 5. Open questions from the plan

- **Bundle identifier.** The macOS app's identifier comes from `$BUNDLE_ID` in
  `Scripts/make-app.sh`. The iOS identifier should share its prefix. Still
  needs a decision.
- **Bonjour service name.** `_cadence._tcp` as proposed is fine technically.
- **cadence-ios** contains only a README and has no licence file yet. The plan
  says MIT; add `LICENSE` in the first pull request there.

## Decisions taken (2026-11-13)

1. **The iOS app uses AVFoundation, not SFBAudioEngine** (option c below). It
   ships no LGPL code and needs no fork. Ogg Vorbis, Ogg Opus, WavPack and
   Monkey's Audio tracks do not play on iOS in the first release; the app must
   show them as unavailable instead of failing silently.
2. **Download to disk, then play.** This follows from decision 1 together with
   gapless playback: scheduling files on `AVAudioEngine` needs local files.
3. **The iOS player engine lives in cadence-ios**, as an implementation of
   CadenceCore's `PlayerEngine`. CadenceAudio stays macOS-only and unchanged.

The options as they were put:

## Decisions needed

1. **LGPL decoders on iOS.** Choose one:
   - **a. Fork SFBAudioEngine** with a trimmed manifest (matches the plan as
     written; costs a fork to keep in step with upstream).
   - **b. Use upstream unchanged**, accepting dynamically linked LGPL
     frameworks in the App Store build.
   - **c. Use AVFoundation on iOS** and drop SFBAudioEngine there (no fork, no
     LGPL; loses Ogg Vorbis, Opus, WavPack and Monkey's Audio on iOS).
2. **Playback starts after download.** Accept download-to-disk before play for
   the first track, since SFBAudioEngine cannot read a network stream.
3. **Where the iOS player engine lives.** Either export CadenceAudio as an iOS
   product (isolating the Core Audio HAL code), or write the iOS engine in
   cadence-ios. This interacts with decision 1: if CadenceAudio is shared and
   option a is chosen, macOS would move to the fork as well, unless the fork
   is applied only on iOS.

## Confirmed without change

- OpenSubsonic wire format, read-only API, API-key authentication, Bonjour
  discovery and original-file streaming are all compatible with what the
  repository provides.
- `LibraryStore` already exposes every read the Phase 2 endpoints need:
  artists, albums, album by key, tracks, search, playlists and liked tracks.
  `ArtworkStore` provides thumbnails and full-size covers for `getCoverArt`.
- Sharing the whole library needs no schema change beyond the ID work above.
