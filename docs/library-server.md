# Library server

The `CadenceServer` target is a read-only HTTP server that lets a paired
Cadence client browse and stream this Mac's library. It speaks the
[OpenSubsonic](https://opensubsonic.netlify.app) API. This note records the
decisions behind it; the code comments carry the detail.

Status: Phase 2 of the build plan, in progress. The server is not reachable
from the app yet and has no library endpoints.

| Built | Not built yet |
|---|---|
| HTTP request parser | Library endpoints (artists, albums, songs, search) |
| OpenSubsonic response envelope and error codes | `stream`, `download`, `getCoverArt` |
| API-key check against a fixed key | Playlists and starred |
| `ping`, `getOpenSubsonicExtensions` | Pairing, per-device keys, TLS, Bonjour (Phase 3) |
| Debug-only loopback listener | A "Share library" switch in the app (Phase 3) |

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
- **Endpoints**: called directly on `LibraryServer`, with a key generated for
  the test run.
- **Socket**: a loopback listener driven by `URLSession`, and by raw streams
  for the cases `URLSession` cannot produce (silence, garbage).

No key is stored in the repository. Tests generate one per run.
