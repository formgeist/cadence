# Third-party licences

Every third-party component Cadence ships, with the licence text it ships under.
`Scripts/make-app.sh` copies this directory into
`Cadence.app/Contents/Resources/Licences`, so a built bundle carries its own
licences rather than pointing at a repository the recipient may never see.

The two font licences are not here — they live beside the fonts they cover, in
`Sources/Cadence/Resources`, and are copied into the same bundle directory at
build time.

## What is bundled

| Component | Licence | File | How it is linked |
|---|---|---|---|
| LAME | LGPL v2 | `LAME.txt` | dynamic framework |
| mpg123 | LGPL v2.1 | `mpg123.txt` | dynamic framework |
| libsndfile | LGPL v2.1 | `libsndfile.txt` | dynamic framework |
| TTA (tta-cpp) | LGPL v3 | `TTA.txt` | dynamic framework |
| FLAC | BSD | `FLAC.txt` | dynamic framework |
| Ogg | BSD | `Ogg.txt` | dynamic framework |
| Vorbis | BSD | `Vorbis.txt` | dynamic framework |
| Opus | BSD | `Opus.txt` | dynamic framework |
| WavPack | BSD | `WavPack.txt` | dynamic framework |
| Musepack (libmpcdec) | BSD 3-clause | `Musepack.txt` | dynamic framework |
| SFBAudioEngine | MIT | `SFBAudioEngine.txt` | source |
| GRDB | MIT | `GRDB.txt` | source |
| Manrope | OFL | `OFL-Manrope.txt` | bundled font |
| IBM Plex Mono | OFL | `OFL-IBMPlexMono.txt` | bundled font |

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

## Refreshing these

Each file is the licence as its own project publishes it, fetched from the
upstream repository. They change rarely, and a stale licence is a worse failure
than a stale screenshot, so re-check them when the pinned versions in
`Package.resolved` move — particularly if a component changes licence between
major versions.
