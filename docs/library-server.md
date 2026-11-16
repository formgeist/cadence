# Library server

The `CadenceServer` target is a read-only HTTP server that lets a paired
Cadence client browse and stream this Mac's library. It speaks the
[OpenSubsonic](https://opensubsonic.netlify.app) API. This note records the
decisions behind it; the code comments carry the detail.

Status: Phases 3 and 4 of the build plan are built. Every
endpoint the plan lists is built, and the app can start the server:
Preferences has a Sharing section with the switch, the pairing code and the
paired devices. Phase 4 is built: `CadenceRemote`, the client the iOS app
uses, is described under [The client](#the-client).

| Built |
|---|
| HTTP request parser |
| OpenSubsonic response envelope and error codes |
| Per-device API keys, stored hashed, revocable; pairing by QR token; rate and stream limits |
| Self-signed certificate, keychain identity, TLS 1.3 listener, Bonjour |
| Sharing in Preferences: switch, QR code, paired devices, title-bar indicator |
| `ping`, `getOpenSubsonicExtensions` |
| `getMusicFolders`, `getArtists`, `getArtist`, `getAlbum`, `getAlbumList2`, `getSong`, `search3` |
| `stream`, `download`, `getCoverArt` |
| `getPlaylists`, `getPlaylist`, `getStarred2` |
| Debug-only loopback listener, `make serve` |
| [`SECURITY.md`](../SECURITY.md): threat model and private reporting |

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

### The sharing demo, for the iPhone app

`make share-demo` runs the real sharing server: TLS, the pairing endpoint and
paired-device keys, the same `LiveSharingBackend` the "Share library" switch
starts. It exists in debug builds only. It keeps a pairing code open and
prints its link whenever a new one opens, once for the simulator (host
127.0.0.1) and once for a phone on the same network:

```bash
make share-demo
```

```bash
xcrun simctl openurl booted 'cadence://pair?v=1&host=127.0.0.1&port=4534&…'
```

It cannot disturb real sharing. It has its own keychain key and certificate,
its own paired-devices file (both in `Application Support/Cadence/share-demo`)
and its own port, 4534, so it runs beside the app's sharing on 4533. A device
paired with the demo is not paired with the app. The identity and devices are
kept between runs, so a simulator stays paired; `make share-demo RESET=1`
forgets them first. `LIBRARY=…` serves another database, as with `make serve`.

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
there and found by a tag of its own. Nothing in Cadence reads its bytes: the
TLS stack asks the keychain to sign with it.

**"Not exportable" holds on macOS 26, and not before.** The key is created
with the not-extractable attribute. macOS 26 enforces it. macOS 15, which CI
runs, ignores it for a key made this way in the login keychain: the app that
made the key can read it back out. This was found by CI, not by reasoning.
What still holds on every system: the key is never in a file, and the
keychain asks the user before letting any other program use it. What is lost
before macOS 26 is one layer of defence: a Cadence that had itself been taken
over could export the key, where on macOS 26 it could only sign with it. A
test records both behaviours, and fails if either changes. Closing the gap on
older systems would mean the data-protection keychain or the Secure Enclave,
both of which need a signing team that community builds do not have.

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

## Being found on the network

When sharing is on, the server announces itself over Bonjour so a phone can
find it without being told an address.

**Service type `_cadence._tcp`** (decided 2026-11-13). The iOS app must list
it under `NSBonjourServices` and browse for it.

**The announcement is a name, a type and a port.** There is no TXT record. It
says a Cadence server is here, and nothing about what is in the library, which
devices are paired, or which version is running. A test reads the record back
and checks it is empty. The name is the Mac's name from System Settings.

**Being found is not being trusted.** Anyone on the network can see the
announcement and connect. They get a TLS handshake and then nothing without a
key. An announcement can also be faked by anything on the network, which is
why the phone trusts the fingerprint from the QR code and not the name it
discovered.

**Off unless asked for.** `HTTPListener.tls` advertises only when given a
name. A test starts one without and checks nothing new appears.

**What the app bundle needed** (`Scripts/make-app.sh`):

| Addition | Why |
|---|---|
| `com.apple.security.network.server` entitlement | A sandboxed build cannot listen without it |
| `NSBonjourServices` with `_cadence._tcp` | The announcement is not allowed unless the type is declared |
| `NSLocalNetworkUsageDescription` | The sentence macOS shows when it asks about local network use |

These are the only network additions. Nothing listens and nothing is
announced until the listener turns sharing on.

## Sharing in the app

Preferences has a Sharing section, built from the same rows and cards as the
rest of the page (decided 2026-11-13: follow the existing patterns, no
separate design pass). `SharingController` holds the state; `SharingBackend`
is the server behind it.

**Off until asked.** The setting defaults to off. Building the controller
starts nothing whatever the saved setting says: the app calls
`resumeIfEnabled()` once, at the end of a normal launch. The headless modes
(`--scan`, `--snapshot`, `--bench` and the rest) return before that line, so
none of them opens a port. The keychain is first read when sharing is
switched on; an app that never shares never asks for it.

**A failed start switches sharing off** and says so. The switch never reads
"on" while nothing is listening.

**Sharing is always visible.** While the server runs, the title bar shows
"Sharing" with a dot; it shows nothing otherwise. Clicking it opens
Preferences.

**Port 4533**, the one Subsonic servers use. If another program holds it the
system picks a free one; the Bonjour announcement and the pairing code carry
whichever it is.

**The pairing code** is the `cadence://pair` link as a QR code, black on
white. The Mac checks the link with the same reader the phone uses before it
shows it. The host in it is the Mac's `.local` name when it has one, else its
IPv4 address on the local network. The link holds the pairing token, so it is
drawn and nothing else: it is not logged, not put on the pasteboard and not
in the accessibility tree, where the code is named "Pairing code" and no
more. The code leaves the screen when the server says it no longer works
(used, run out, or spoiled by wrong guesses), and Preferences says which
device paired, or that none did.

**Paired devices** are listed with when they paired and when they last
connected. They stay listed with sharing off, so access can be taken away
without switching the server on. Removing one asks first, then locks the
device out at once. If the change cannot be written to disk, Preferences says
so: a device removed only in memory would be back after a restart.

**The fingerprint** is shown in sixteen groups of four while sharing is on,
for comparing by eye with what the phone shows for a paired server.

**Preview mode** (snapshots, design review) uses a canned backend: no port,
no file, no keychain, a made-up Mac name and two made-up devices.

**Not checked yet:** the sandboxed app bundle creating the keychain key, and
macOS's local-network permission prompt. Both need the built app run by hand.

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

The limit on concurrent streams per device and the timeout for a client that
stops reading are described under Limits.

## Limits

Set in `HTTPRequestParser.Limits`, `HTTPListener.Limits` and
`LibraryServer.Configuration`.

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
| Failed sign-ins from one address | 10 in 60 s, then blocked for 60 s | 429 with `Retry-After` |
| Files being sent to one device at once | 4 | 429 with `Retry-After` |
| Time a client may go without reading a file it is being sent | 30 s | Connection closed |

**Failed sign-ins are limited by address.** A failed sign-in is a request
with a missing or wrong key, or a pairing request that was refused. Ten from
one address inside a minute and that address is refused for a minute: every
request, before any key is looked at, a correct key included. Checking a key
during a block would defeat it, since "is this key right?" is the answer a
guesser wants. Requests that succeed are never counted, and neither is an
error after a valid key, such as an unknown id.

This does not make keys safer; 256 random bits need no help. It stops a
device hammering the server, makes a pairing token's few attempts harder to
spend from one place, and keeps a broken client from flooding the log.

**The address is the socket's.** The listener takes it from the connection.
Nothing a client sends can change it: `X-Forwarded-For` and its relatives are
ignored, and a test sends them to check. At most 1,024 addresses are
remembered, so a flood of addresses cannot grow the table without end.

**A device may be sent four files at once.** A stream holds a file open and a
connection busy for as long as the client reads. Without a cap, one device or
one stolen key could take every connection. Only a response that will send a
file takes a place: an error, or a range outside the file, takes none.
Browsing is not limited by streams in use. A place is given back when the
connection closes, however it closes; the listener calls the response's
`onFinish` exactly once, including when the client left before the answer was
ready.

**A client that stops reading is dropped after 30 seconds.** Each piece of a
file must be taken by the network within the stall timeout. A test asks for a
64 MB file, reads nothing, and checks that the server closes the connection
and frees the place.

Not limited yet: the total rate of requests from a paired device. A device
with a valid key can ask as fast as its connections allow.

## The client

`CadenceRemote` is the other end: a library product, built for macOS and iOS,
that the iOS app uses to pair and to read the library. Apple frameworks only,
and it depends on CadenceCore alone, so it never pulls the server into the
phone.

| Type | Does |
|---|---|
| `RemotePairing.pair` | Trades a scanned `PairingPayload` for `RemoteCredentials` |
| `RemoteLibraryClient` | One method per endpoint: browse, search, playlists, likes, `download`, `coverArt` |
| `RemoteError` | Every failure, in terms the app can act on |

**The pin is checked on every request, by that request.** Each request passes
its own task delegate, which compares the SHA-256 of the leaf certificate
with the paired fingerprint and cancels the challenge on any other. A refused
challenge reaches the caller as a cancellation; because the check belongs to
the request, the client can tell it apart and report `.untrustedServer`. Host
name, expiry and chain are not consulted, as the certificate section explains.

**Pairing checks before it spends the token.** It connects to the address in
the code and checks the certificate first, so an impostor never sees the
token. It then reads the protocol version from `getOpenSubsonicExtensions`,
the one endpoint without a key, so a mismatched server is refused before it
makes a key no one could use. Only then does it `POST /pair`.

**The protocol version is checked on every answer**, not only at `connect()`,
so a Mac updated while the phone app is open is caught on the next request.
`RemoteLibraryClient.protocolVersion` must equal the server's
`cadenceProtocolVersion`; a test fails if they part.

**Nothing keeps a URL with a key in it.** The protocol puts the key in the
query string, so the session is ephemeral with no URL cache and no cookies.
`RemoteCredentials` holds the key, and the app must keep it in the keychain.

**Errors.** Codes 40 to 44 all become `.notPaired`: whichever it is, the way
in is gone and pairing again is the fix. 70 is `.notFound`, 429 is
`.busy(retryAfter:)`. "Not connected" is `.offline`; every other transport
failure, from a timeout to a refused connection, is `.unreachable`, which is
what a sleeping Mac looks like. A cancelled task throws `CancellationError`,
as `TrackSource` requires.

**Mapping.** `Track(remote:)`, `Album(remote:)`, `Artist(remote:)` and
`Playlist(remote:)` turn answers into CadenceCore's models. Track and playlist
ids are the Mac's own UUIDs, read back out of `tr-` and `pl-` ids, and an
album's key is rebuilt from the same artist, title and year, so its
`stableID` is the id the server sent. A remote track's `url` is
`cadence-remote://song/<id>?suffix=flac`: it names the song and nothing about
the server, so a saved queue survives the Mac's address changing. A song
fetched without its album names only its own artist, which then stands in for
the album artist until the album is loaded.

**Playing.** `RemoteTrackSource` is the `TrackSource` for a paired library. It
downloads a song's whole file into a cache folder and hands the engine that
file. Two callers asking for one song share one download; a caller that is
cancelled (a skip) is answered at once, and the download stops when no one is
left waiting. A download is written to a hidden partial file and renamed into
place only when complete. The folder has a byte budget, 2 GB by default; past
it, the files used longest ago are removed, never the ones handed out most
recently, which an engine may have open. Failures reach the engine as
`PlaybackError.engine` with `RemoteError.message`, a sentence for the listener.

**Browsing without the Mac.** `RemoteMetadataCache` keeps the last answer to
each browse request as a file, keyed by a digest of the endpoint and its
parameters, as the recon note chose: no database, so GRDB stays off the
phone. Browse methods take `source: .cache` to read it without asking the
Mac, and throw `.notCached` when there is nothing. Search, single songs and
random album lists are never cached. An answer is stored only after it has
decoded, and the key is never part of a file name or a file.

**Reconnecting.** `RemoteConnection` holds one state for the app to show:
connecting, connected, offline, unreachable, or needs attention. It watches
the network with `NWPathMonitor`. A Mac that does not answer is retried after
2, 4, 8… seconds, at most a minute apart, and at once when the network
changes. A busy Mac is retried when it said to. A revoked key, a changed
certificate or a version mismatch is `.needsAttention` and is not retried
until the app calls `retryNow()`, since only the user can fix it. A request
that fails with `.unreachable` while connected is reported with
`connectionLost(_:)`, which starts reconnecting.

## Testing

- **Parser**: accepted and refused inputs case by case, plus two seeded fuzz
  tests (random bytes, and mutations of a valid request) that assert it never
  crashes.
- **Endpoints**: called directly on `LibraryServer`, against a real SQLite
  store in a temporary folder, with a key generated for the test run. They
  include hostile ids and queries, and a check that no response contains a
  path.
- **Fuzzing in CI.** The fuzz tests are ordinary tests with fixed seeds, so
  they run on every push and a failure reproduces: the request parser (random
  bytes, mutated `GET`, mutated `POST`), byte ranges, and the pairing payload.
- **Large data.** Tests compare big blobs with a helper that returns a `Bool`.
  A failed `#expect(a == b)` on 300,000 bytes made the test framework spend
  over eight minutes computing a difference to print.
- **Sharing controller**: against a fake backend, so the switch, quick
  toggles, failed starts, pairing and removal are tested without a port. The
  real backend is tested against a scratch library, a scratch device file and
  a keychain item of its own.
- **Socket**: a loopback listener driven by `URLSession`, and by raw streams
  for the cases `URLSession` cannot produce (silence, garbage).

- **Client**: `CadenceRemoteTests` starts a real server on the loopback
  interface over TLS, pairs with it from a pairing code, browses, and
  downloads a song's bytes. It checks that a wrong fingerprint is refused
  before the token is spent, that a revoked device is told so, and that a
  stopped server is unreachable. The track source, the metadata cache and
  the mapping are tested against the same live server; shared and cancelled
  downloads and the budget against a stand-in downloader that can hold a
  download open; reconnecting against a scripted server and network.

No key is stored in the repository. Tests generate one per run.
