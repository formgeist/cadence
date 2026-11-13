# Library server

The `CadenceServer` target is a read-only HTTP server that lets a paired
Cadence client browse and stream this Mac's library. It speaks the
[OpenSubsonic](https://opensubsonic.netlify.app) API. This note records the
decisions behind it; the code comments carry the detail.

Status: Phase 2 of the build plan, in progress. The server is not reachable
from the app yet.

| Built | Not built yet |
|---|---|
| HTTP request parser | Playlists and starred |
| OpenSubsonic response envelope and error codes | A way to start the server from the app |
| API-key check against a fixed key | Pairing, per-device keys, TLS, Bonjour (Phase 3) |
| `ping`, `getOpenSubsonicExtensions` | A "Share library" switch in the app (Phase 3) |
| `getMusicFolders`, `getArtists`, `getArtist`, `getAlbum`, `getAlbumList2`, `getSong`, `search3` | |
| `stream`, `download`, `getCoverArt` | |
| Debug-only loopback listener | |

## Shape

```
socket ──▶ HTTPListener ──▶ HTTPRequestParser ──▶ LibraryServer ──▶ HTTPResponse ──▶ socket
```

`LibraryServer` takes a parsed request and returns a response. It knows
nothing about sockets, so every endpoint is tested by calling it directly.
`HTTPListener` is the only part that touches the network.

## Decisions

**No dependency.** The listener is Network.framework, and the HTTP parser is
ours. The reasoning is in [server-ios-recon.md](server-ios-recon.md), section 4.

**Read-only by construction, at three levels.** The parser accepts `GET` and
`HEAD` only and refuses any request body. The route table holds no endpoint
that changes anything. A test asserts that the Subsonic API's write endpoints
are not routed.

**One request per connection.** Every response carries `Connection: close`.
This removes pipelining and any question of where one request ends and the
next begins. It costs a TCP and, later, a TLS handshake per request. If
browsing proves slow in Phase 4, keep-alive is the first thing to revisit.

**JSON only.** The protocol's default response format is XML. Cadence's own
clients ask for JSON, and they are the only supported clients, so the server
always answers in JSON whatever `f` says.

**Protocol errors are HTTP 200.** As the Subsonic API specifies, a failure is
a normal response with `"status": "failed"` and an `error` object. HTTP error
statuses are used only where the request never reached an endpoint: a
malformed request, a method other than `GET` or `HEAD`, or an unknown path.

**API keys are the only way in.** The server advertises OpenSubsonic's
`apiKeyAuthentication` extension and nothing else.

| Request carries | Answer |
|---|---|
| A valid `apiKey` | The endpoint's response |
| No key, or a wrong one | Error 44, the same bytes for both |
| A user name, password or token, and no key | Error 42 (mechanism not supported) |
| A key together with a user name | Error 43 (conflicting mechanisms) |

A user name and password are refused as a mechanism and never checked, so
there is no password to guess. `getOpenSubsonicExtensions` is the one endpoint
that needs no key, as the extension requires: it is how a client learns which
mechanisms exist.

**Keys are compared by digest.** The server holds a SHA-256 of each key, never
the key, and compares digests in constant time.

**A Cadence protocol version rides in every response.** Beside the Subsonic
API `version`, the envelope carries `cadenceProtocolVersion` (currently 1) and
`serverVersion`. A client compares the protocol number at connect time, so a
mismatched app and server fail with a clear message.

**Paths are matched, never interpreted.** A request path is compared against
the route table and used for nothing else. No part of a request is ever joined
to a directory. Files will be reached only through library ids.

**No plain HTTP in a release build.** The only public way to create a listener
is `HTTPListener.loopback`, which binds to 127.0.0.1 and is compiled in debug
builds only. A release build of `CadenceServer` contains no code that can
start a listener; Phase 3 adds the TLS one.

## The library on the wire

**Ids.** Every id a client sees is opaque and prefixed by kind, so an id sent
to the wrong endpoint fails to parse instead of finding something else.

| Kind | Form | Source |
|---|---|---|
| Song | `tr-` and a lowercase UUID | The track's stored id |
| Album | `al-` and 32 hex characters | `StableID`, a digest of artist, title and year |
| Artist | `ar-` and 32 hex characters | `StableID`, a digest of the album-artist name |
| Cover art | 64 hex characters | The artwork's content address |

An id that is malformed, of the wrong kind, never issued or no longer in the
library gets one answer: error 70, "Not found."

**Artists are album artists.** `getArtists` lists the names albums are filed
under, the same list the Mac app's Artists screen shows. A song's `artistId`
is therefore its album artist's id, which is the artist a client can open,
while its `artist` is the track artist as tagged.

**No paths.** The protocol's optional `path` field is never sent. A song
reports its extension and content type and nothing else about its file. The
library is presented as one music folder named "Library".

**`getAlbumList2` types.**

| Type | Behaviour |
|---|---|
| `alphabeticalByName`, `alphabeticalByArtist`, `newest`, `random` | Supported |
| `byYear` | Needs `fromYear` and `toYear`; a reversed range lists newest first |
| `byGenre` | Needs `genre`; matches ignoring case and accents |
| `recent`, `frequent`, `highest`, `starred` | Answered with an empty list |

The last row is deliberate. The protocol defines those lists over play counts
and ratings kept per album id, which this library does not keep in that form.
An empty list is a valid answer and does not hand a client an error.

`size` defaults to 10 and is capped at 500. A value over the cap is brought
down to it; a value that is not a plain non-negative integer is error 10.

**`search3`.** Songs come from the store's full-text index, the same search
the Mac app uses, which builds its pattern from the letters and digits of the
query alone. Albums and artists match when every word of the query appears in
the name, ignoring case and accents. An empty query returns the whole library
a page at a time, as the protocol defines, which is how a client can mirror
the library's metadata. A non-empty query returns at most 100 songs in total.

**Cost.** Album lists are built from one grouped query over the track table
and never load tracks. `getAlbum` and `getArtist` read only the rows they
need. Nothing is cached between requests yet; `make bench` timings come with
the debug harness later in this phase.

## Audio and cover art

`stream`, `download` and `getCoverArt` answer with bytes, not an envelope. A
failure is still a JSON envelope; a client tells the two apart by content
type.

**The request names a thing by id; the server decides where it is.** A song
id is looked up in the library, and the library's own record says which file
to open. Nothing a client sends is used as, or joined into, a path.

**No transcoding.** `stream` and `download` both send the original file. The
protocol's `maxBitRate` and `format` parameters are ignored.

**Byte ranges.** One range in bytes is honoured, in the three forms a player
seeks with: `a-b`, `a-` and `-n`. An end past the file is brought back to its
last byte. A range that starts outside the file is 416 with the file's size.
Anything else, including several ranges at once, is ignored and answered with
the whole file, as RFC 9110 permits.

**Files are sent in 64 KB pieces**, each read only after the one before it
has been handed to the network, so a slow client holds one piece in memory
and not the file.

**A file is opened with `O_NOFOLLOW` and must be a regular file.** The path
was true when the library was scanned, not necessarily now. A file since
swapped for a symbolic link or a directory is refused, so the server only
sends what the scanner read. The file is opened before the response head is
sent: if it has gone or shrunk in between, the client gets a 500 and not a
head followed by a short body.

**A cover id must be a content address**: exactly 64 lowercase hex
characters. The artwork store builds a file name from the id, so this check
is what keeps a cover request inside the artwork folder.

**Cover sizes are rounded up to 64, 128, 256, 512 or 1024 pixels.** The
artwork store keeps one thumbnail file per cover per size; without the
rounding, a client could fill the disk by asking for every size in turn.
Sized covers are PNG. With no `size`, the stored original is sent.

**Image types are read from the bytes.** Cover bytes come from tags in music
files. JPEG, PNG, GIF and WebP are served; anything else is "not found".

Not built yet: a limit on concurrent streams per device, and a timeout for a
client that stops reading mid-stream. Both belong to Phase 3.

## Limits

Set in `HTTPRequestParser.Limits` and `HTTPListener.Limits`.

| Limit | Value | Refused with |
|---|---|---|
| Request line and headers | 16 KB | 431 |
| Request target | 8 KB | 414 |
| Headers | 64 | 431 |
| Query parameters | 64 | 414 |
| Request body | 0 bytes | 413 |
| Open connections | 32 | Closed unanswered |
| Time to send the request head | 10 s | 408 |

Limits on concurrent streams per device and rate limiting of failed
authentication belong to Phase 3, with pairing.

## Testing

- **Parser**: accepted and refused inputs case by case, plus two seeded fuzz
  tests (random bytes, and mutations of a valid request) that assert it never
  crashes.
- **Endpoints**: called directly on `LibraryServer`, against a real SQLite
  store in a temporary folder, with a key generated for the test run. They
  include hostile ids and queries, and a check that no response contains a
  path.
- **Socket**: a loopback listener driven by `URLSession`, and by raw streams
  for the cases `URLSession` cannot produce (silence, garbage).

No key is stored in the repository. Tests generate one per run.
