# Library server

The `CadenceServer` target is a read-only HTTP server that lets a paired
Cadence client browse and stream this Mac's library. It speaks the
[OpenSubsonic](https://opensubsonic.netlify.app) API. This note records the
decisions behind it; the code comments carry the detail.

Status: Phase 2 of the build plan. Every endpoint the plan lists is built.
The server runs from a debug build on the loopback interface only; nothing in
a release build can start it yet.

| Built | Not built yet |
|---|---|
| HTTP request parser | Starting the TLS listener from the app |
| OpenSubsonic response envelope and error codes | Bonjour |
| Per-device API keys, stored hashed, revocable; pairing by QR token | A "Share library" switch in the app (Phase 3) |
| Self-signed certificate, keychain identity, TLS 1.3 listener | |
| `ping`, `getOpenSubsonicExtensions` | |
| `getMusicFolders`, `getArtists`, `getArtist`, `getAlbum`, `getAlbumList2`, `getSong`, `search3` | |
| `stream`, `download`, `getCoverArt` | |
| `getPlaylists`, `getPlaylist`, `getStarred2` | |
| Debug-only loopback listener, `make serve` | |

## Running it

`make serve` starts the server on 127.0.0.1, on a port the system picks, and
prints the address. It exists in debug builds only.

The API key is read from the environment variable `CADENCE_DEV_API_KEY` and
must be at least 32 characters. It is never printed. Set one for the shell
session, start the server, and call it from a second terminal that has the
same variable:

```bash
export CADENCE_DEV_API_KEY="$(uuidgen)$(uuidgen)"
```

```bash
make serve
```

```bash
curl "http://127.0.0.1:PORT/rest/ping?apiKey=$CADENCE_DEV_API_KEY"
```

By default it serves the app's real library. `make serve LIBRARY=/path/to.sqlite`
serves another, such as one written by `make scan … LIBRARY=…`.

Like the other harnesses, `--serve` launches the app binary, which reads the
keychain at launch. `make serve` signs the binary with the local signing
certificate when you have one, so that read does not stop at a prompt after
every rebuild. Without the certificate it can: the server then prints nothing
and appears to hang. CONTRIBUTING.md, "A stable signature for local builds",
says how to make the certificate.

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

**The library is read-only by construction, at three levels.** Everything
under `/rest/` is reached with `GET` or `HEAD` only; the router refuses `POST`
there. The route table holds no endpoint that changes anything. A test asserts
that the Subsonic API's write endpoints are not routed. The one request that
changes anything is `POST /pair`, described under Pairing, which can add a
paired device and nothing else.

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
the key.

## Paired devices

`PairedDeviceStore` holds the devices that may read the library and is the
only place a key is checked. Pairing, below, is what adds a device to it.
Nothing in the app opens pairing yet, and the debug harness still uses one
fixed key.

**One key per device.** Pairing mints 256 random bits from the system
generator, as 43 characters of URL-safe base64. The key is returned once, to
be handed to the device, and is not kept on the Mac.

**Stored hashed.** For each device the store keeps an id, a name, the date it
was paired, when it was last seen, and the SHA-256 of its key. A plain SHA-256
is enough, where it would not be for a password, because the key is random:
there is nothing to guess faster than trying keys.

**Revoking is immediate.** Every request asks the store, which answers from
memory, and a revoked device is gone from that memory before `revoke` returns.
There is no cache of earlier answers for a revoked key to survive in.

**One file, owner-readable only.** `paired-devices.json` in the app's
Application Support folder, mode 0600, written to a new file and moved into
place so it is never half-written. It is kept apart from the library database:
resetting a library should not unpair every phone.

**Limits.** At most 32 devices. A device's name comes from the network, so it
is cut to 64 characters and stripped of control characters before it is kept.

**A file the app cannot read is refused, not replaced.** The store fails to
open and leaves the file as it is. No device is accepted in that state.

**"Last seen" is written at most once a minute.** It is exact in memory and
approximate on disk.

Known gap: if the file cannot be rewritten when a device is revoked, the
device is refused for the rest of that run but is still in the file, and would
be accepted again after a relaunch. `revoke` reports the failure so the app
can say so.

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

## Pairing

A new device gets its key by pairing. The Mac shows a six-digit code; the
device sends it back and is given a key.

```
POST /pair
Content-Type: application/json

{"code": "482915", "name": "Casper's iPhone"}
```

On success, 200 with the key. This is the only time the key is sent:

```
{"apiKey": "…", "deviceId": "…", "serverVersion": "…", "cadenceProtocolVersion": 1}
```

On any failure, 403 with `{"error": "pairing_failed"}`.

`/pair` is not part of the OpenSubsonic API and sits outside `/rest/` to say
so. It is the one request a device may make without a key, since getting a
key is its purpose, and the one request that changes anything.

**What makes six digits safe.** A person has to type the code, so it is
short. Everything around it does the work:

| Rule | Value |
|---|---|
| Pairing is open only while the user has a code on screen | Otherwise every request is refused |
| A code works once | Including when requests arrive with it together: one pairs, the rest are refused |
| A code expires | After 5 minutes |
| A code allows a few attempts | 5; the fifth wrong one cancels it |
| Every refusal is the same | Wrong, expired, used and "not open" are one identical response |

A stranger on the network therefore has five chances in a million per code
the user chooses to show. The cost of the attempt limit is that the same
stranger can spoil a code by guessing five times; the user asks for another.

**The request must be exactly JSON.** Any other content type is 415. A web
page cannot send `application/json` to another origin without the browser
asking the server first, and this server never agrees, so a page the user
happens to have open cannot pair on their behalf. A body that is not a valid
pairing request is 400 and is not counted as an attempt.

**The device's name is cleaned** before it is kept, as described under
Paired devices.

**Pairing must not ship before TLS.** Over plain HTTP the code and the key
both cross the network in the clear. That is acceptable only on the debug
loopback listener, which is the only listener that exists today.

**Two secrets, for two ways of pairing.** Opening pairing makes both, with
one lifetime and one shared attempt limit:

| Secret | Form | Who sends it | Sent as |
|---|---|---|---|
| Token | 256 random bits, 43 characters | A device that scanned the QR code | `{"token": "…", "name": "…"}` |
| Code | Six digits | A device whose user typed it | `{"code": "…", "name": "…"}` |

A request carries exactly one of the two.

**Pairing by QR code is safe as it stands.** The QR code holds a
`PairingPayload` (in CadenceCore, shared with the iOS app):

```
cadence://pair?v=1&host=studio-mac.local&port=4533&fp=<fingerprint>&token=<token>&name=Studio%20Mac
```

The phone connects to `host`, checks that the server's certificate has the
fingerprint `fp`, and only then sends the token. Something answering in the
Mac's place cannot present that certificate, so it never sees the token. The
payload parser is strict, because a QR code is outside input: every field
once, known fields only, and a host that can only be a host. A code from a
newer version is reported as such, apart from every other error, so the app
can say "update needed". An IPv6 host is written bare; a client must add the
brackets when it builds a URL from it.

**Typed codes are switched off, and must stay off for now.** A device whose
user types six digits has no fingerprint to check the server against. On a
hostile network, something answering in the Mac's place could collect the
digits and pair itself with the real Mac. So `PairingSession` refuses the
digits unless it is created with `allowsTypedCode: true`, which nothing in the
app does. With it off, the right digits are refused and do not count as an
attempt.

The token and the digits are deliberately different secrets. If the QR code
carried the digits, the server could not tell a device that had verified the
certificate from one that had been tricked into revealing the digits.

**The first release pairs by QR code only. Decided 2026-11-13.** Typed codes
stay switched off, and the iOS design's "Enter code" screen goes unused. The
phone needs camera permission to pair.

The earlier decision was a confirmation on the Mac: both screens show the
same short number and the user confirms. Designing it showed that a number
the Mac simply sends is not enough, because whatever sits in the middle can
alter it in transit and search for a value that makes the two screens agree.
Doing it soundly takes a commit-and-reveal exchange, three requests in place
of one, in which each side fixes its random value before seeing the other's.
That is a small cryptographic protocol of our own. It can be added later
without changing QR pairing, as a project of its own with a review.

## The certificate

The server will present a certificate the Mac makes for itself, and a paired
device trusts it by pinning: it learns the certificate's SHA-256 fingerprint
at pairing and from then on accepts that exact certificate and no other.
`SelfSignedCertificate` builds it.

**Why make our own.** No certificate authority vouches for a name like
`studio-mac.local`, and the plan rules out anything that needs one. Apple's
frameworks can generate a key and sign with it but have no public way to build
a certificate, so this is a small DER encoder for one shape of certificate:
X.509 version 3, a P-256 key, ECDSA with SHA-256. It only encodes, and only
values it constructs itself; it never reads bytes from the network.

**What is in it.** A random 16-byte serial, a common name for people to read,
the public key, and three extensions: not a certificate authority, usable for
digital signatures, usable as a TLS server. Nothing private goes in the name.

**It lasts ten years, deliberately.** A pinned certificate is trusted for
being the one that was shown, not for being in date. One that expired would
silently unpair every device.

Ten years is more than the 825 days Apple's TLS server policy allows, so the
system's default evaluation rejects it, for that reason alone. Tests pin this
down both ways: with an 800-day lifetime the certificate passes Apple's
strict TLS server evaluation in full, and at ten years the lifetime is the
only objection. This is expected. A Cadence client never asks the system
whether to trust the server; it compares the fingerprint. The consequence for
Phase 4: the client must make that comparison in its trust handler and must
not fall back to default evaluation.

**The fingerprint** is the SHA-256 of the certificate's DER bytes, in
lowercase hex.

## The identity and the TLS listener

`ServerIdentityStore` keeps the key and the certificate, and
`HTTPListener.tls` serves with them. Nothing in the app starts the TLS
listener yet; that comes with the "Share library" switch.

**The private key lives in the keychain and nowhere else.** It is generated
there, marked not extractable, and found by a tag of its own. Nothing in
Cadence reads its bytes: the TLS stack asks the keychain to sign with it. A
test asserts the key cannot be exported.

**The certificate lives in a file**, `server-certificate.der` in Application
Support. It is public: the server hands it to anyone who connects. It is kept
in a file and not beside the key because a keychain search matches
certificates and identities by label loosely. The first version of this
looked the identity up by label and was handed a different identity
altogether; a path cannot do that.

**The identity is made once.** Every paired device has pinned it, and a new
one unpairs them all. `loadOrCreate` creates only when there is no complete
identity to load. A certificate whose key is missing, or a file that is not a
certificate, counts as none and is replaced. `reset` removes both halves and
goes with unpairing every device.

**TLS 1.3 only.** Both ends are Cadence on current systems, so there is no
older client to allow for. A test reads the negotiated version.

**A release build has this listener and no other.** The plain-HTTP loopback
listener is still compiled into debug builds only.

**What a client must do** is shown by the tests, which connect with
`URLSession` the way the iOS app will:

| Client | Result |
|---|---|
| Pins the server's fingerprint | Connects |
| Pins a different fingerprint | Refuses the server |
| Does not pin, and relies on default evaluation | Refuses the server |
| Speaks plain HTTP to the TLS port | Gets nothing |

The third row is the ten-year lifetime at work: a client that forgets to pin
fails to connect, loudly, and cannot be fooled quietly.

**Known limits.** Keychain access is serialised inside the store, because two
identities being made at the same moment made key generation fail. The tests
make real keys in the user's login keychain, under tags of their own, and
delete them; an interrupted test run can leave one behind.

## The library on the wire

**Ids.** Every id a client sees is opaque and prefixed by kind, so an id sent
to the wrong endpoint fails to parse instead of finding something else.

| Kind | Form | Source |
|---|---|---|
| Song | `tr-` and a lowercase UUID | The track's stored id |
| Album | `al-` and 32 hex characters | `StableID`, a digest of artist, title and year |
| Artist | `ar-` and 32 hex characters | `StableID`, a digest of the album-artist name |
| Playlist | `pl-` and a lowercase UUID | The playlist's stored id |
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

**Playlists.** `getPlaylists` lists every playlist in the Mac's sidebar
order. Sidebar folders have no counterpart in the protocol, so the list is
flat. `getPlaylist` returns the songs in playlist order, with a song repeated
where the playlist repeats it. The Mac records when a playlist last changed
and not when it was made, so `created` and `changed` both carry that date, and
both are left out for a playlist older than the record. A playlist with no
cover of its own borrows the first one among its songs.

**Liked Songs are `getStarred2`.** Songs come back most recently liked first,
each with the moment it was liked in `starred`. The Mac likes songs only, so
the starred artist and album lists are always empty. A song carries `starred`
only in this answer; `getSong`, `getAlbum` and the rest do not report it.

Both are read-only, like everything else: there is no endpoint to create or
change a playlist, or to like a song.

**Cost.** Album lists are built from one grouped query over the track table
and never load tracks. `getAlbum` and `getArtist` read only the rows they
need. Nothing is cached between requests.

`make bench` times the server end to end, without a socket: authentication,
the store reads and the JSON encoding. On the 30,000-track synthetic library
(2,500 albums, 250 artists), one release-build run on an Apple silicon Mac:

| Request | Time |
|---|---|
| `getArtists` | 37 ms |
| `getAlbumList2`, newest, 500 albums | 40 ms |
| `getAlbumList2`, by name, 500 albums | 43 ms |
| `getAlbum` | 1 ms |
| `search3` "slow" | 78 ms |
| `search3` "a" (broad) | 119 ms |
| `search3`, empty query, 500 of each | 114 ms |

These are single runs, not averages. They are low enough that a cache is not
worth its invalidation yet. Search is the slowest because it reads the artist
and album lists on every call as well as the full-text index; that is the
place to look first if it ever matters.

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
| Request body, `GET` and `HEAD` | 0 bytes | 413 |
| Request body, `POST` | 1 KB, length declared | 413, or 411 with no length |
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
