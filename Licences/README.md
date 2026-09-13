# Third-party licences

Every third-party component Cadence ships, with the licence text it ships under.
`Scripts/make-app.sh` copies this directory into
`Cadence.app/Contents/Resources/Licences`, so a built bundle carries its own
licences rather than pointing at a repository the recipient may never see.

The two font licences are not here — they live beside the fonts they cover, in
`Sources/Cadence/Resources`, and are copied into the same bundle directory at
build time.

## What is bundled

Two different things ship under "source": `SFBAudioEngine` and `GRDB` are
substantial libraries Cadence's own code calls into. The nine packages in the
second table are smaller dependencies of `SFBAudioEngine` itself — codec
backends and utility types — that arrive as Swift Package Manager source
packages and get compiled straight into `Contents/MacOS/Cadence` alongside
everything else. Neither table is inferred from `Package.resolved` alone: what
lands in `Contents/Frameworks` as a `.framework` is dynamic, everything else
that reaches the shipped binary is compiled in, and `otool -L
Cadence.app/Contents/MacOS/Cadence` is the way to check which is which for any
future addition.

### Dynamic frameworks

| Component | Licence | File |
|---|---|---|
| LAME | LGPL v2 | `LAME.txt` |
| mpg123 | LGPL v2.1 | `mpg123.txt` |
| libsndfile | LGPL v2.1 | `libsndfile.txt` |
| TTA (tta-cpp) | LGPL v3 | `TTA.txt` |
| FLAC | BSD | `FLAC.txt` |
| Ogg | BSD | `Ogg.txt` |
| Vorbis | BSD | `Vorbis.txt` |
| Opus | BSD | `Opus.txt` |
| WavPack | BSD | `WavPack.txt` |
| Musepack (libmpcdec) | BSD 3-clause | `Musepack.txt` |

### Compiled in from source

| Component | Licence | File |
|---|---|---|
| SFBAudioEngine | MIT | `SFBAudioEngine.txt` |
| GRDB | MIT | `GRDB.txt` |
| CXXTagLib (TagLib) | MPL 1.1 | `CXXTagLib.txt` |
| CXXMonkeysAudio (Monkey's Audio) | BSD 3-clause | `CXXMonkeysAudio.txt` |
| CDUMB (DUMB) | zlib-style | `CDUMB.txt` |
| CSpeex (Speex) | Xiph BSD | `CSpeex.txt` |
| AVFAudioExtensions | MIT | `AVFAudioExtensions.txt` |
| CXXAudioRingBuffer | MIT | `CXXAudioRingBuffer.txt` |
| CXXRingBuffer | MIT | `CXXRingBuffer.txt` |
| CXXUnfairLock | MIT | `CXXUnfairLock.txt` |
| CXXDispatchSemaphore | MIT | `CXXDispatchSemaphore.txt` |

### Bundled fonts

| Component | Licence | File |
|---|---|---|
| Manrope | OFL | `OFL-Manrope.txt` |
| IBM Plex Mono | OFL | `OFL-IBMPlexMono.txt` |

## The LGPL components

Four of them, not the three the top-level README claimed before this directory
existed, and not the three it named. The list was assembled by reading what each
component actually ships rather than by reputation:

- **LAME** is under the *Library* GPL v2 of June 1991, not the Lesser GPL v2.1.
  A single shared "LGPL-2.1.txt" would have shipped it the wrong text.
- **libsndfile** (LGPL v2.1) and **TTA** (LGPL v3) are LGPL and were missing
  from the count entirely.
- **Musepack** was named as LGPL and is not. Only the encoder is; the decoder —
  `libmpcdec`, the half Cadence uses — is BSD 3-clause. The encoder is not
  bundled.

What the LGPL asks of an MIT application is that these stay *dynamically*
linked, so a recipient can replace them. `make-app.sh` copies each as a
`.framework` into `Contents/Frameworks` and adds an rpath, which is what keeps
that true. Merging any of them into the binary would forfeit it.

The BSD components ask only that their copyright notice and disclaimer be
reproduced in the materials shipped with a binary. That is what this directory
is.

## The compiled-in components

Nine packages arrive as source and are compiled straight into
`Contents/MacOS/Cadence`. Unlike the LGPL frameworks above, none of them
creates a static-linking problem for an MIT app — but each was checked against
the licence its own repository publishes, rather than assumed, because one of
them could easily have been a problem:

- **CXXTagLib** publishes TagLib under **MPL 1.1**. TagLib is actually
  dual-licensed LGPL-2.1-or-later *or* MPL 1.1; had the LGPL half been elected
  instead, compiling it into the binary would have forfeited MIT
  compatibility the same way the frameworks above would if merged in — and it
  would have done so silently, since nothing about a source package flags it
  the way a `.framework` in `Contents/Frameworks` does. MPL 1.1 is file-level
  copyleft: it explicitly permits combining covered files into a Larger Work
  under other terms, and only requires the licence accompany the covered code
  and that modifications to MPL-covered files be published. Cadence doesn't
  modify TagLib, so only the first applies.
- **CXXMonkeysAudio** (Monkey's Audio) and **CSpeex** (Speex) are BSD, same
  obligation as the BSD frameworks above.
- **CDUMB** (DUMB) is zlib-style permissive. Its licence also *asks* for
  acknowledgement and a link to the project, though it doesn't strictly
  require either — worth honouring anyway: this file is that acknowledgement,
  and the link is https://github.com/kode54/dumb.
- The remaining five (**AVFAudioExtensions**, **CXXAudioRingBuffer**,
  **CXXRingBuffer**, **CXXUnfairLock**, **CXXDispatchSemaphore**) are MIT,
  same obligation as SFBAudioEngine and GRDB above.

## Refreshing these

Each file is the licence as its own project publishes it, fetched from the
upstream repository. They change rarely, and a stale licence is a worse failure
than a stale screenshot, so re-check them when the pinned versions in
`Package.resolved` move — particularly if a component changes licence between
major versions.

`Package.resolved` alone isn't reliable for telling which packages reach the
shipped binary: a package can be pinned there and still be scoped only to a
test target (as `swift-syntax` is, via `swift-testing`) and never link into
the app. Run `otool -L Cadence.app/Contents/MacOS/Cadence` against a real
build — anything in `Package.resolved` that is *not* in that output and *not*
an xcframework is a source package compiled straight into the binary, and
belongs in the second table above. Re-run this check whenever a dependency is
added, since that's how the nine packages above went unlisted for as long as
they did.
