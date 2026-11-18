# Security policy

## Reporting a vulnerability

Report it privately through GitHub:
[**Report a vulnerability**](https://github.com/formgeist/cadence/security/advisories/new)
(the repository's Security tab, then "Report a vulnerability").

Please do not open a public issue, pull request or discussion for a
vulnerability. A private report lets a fix ship before the problem is
public.

A useful report says:

- what an attacker can do, and from where (same Wi-Fi, a paired device, a
  file in the library, …);
- the Cadence version or commit, and the macOS or iOS version;
- the steps or a request that shows it. A proof of concept against your own
  Mac is enough; please do not test against other people's machines.

Cadence is maintained by one person. Reports are read and answered as soon as
possible, and you will be told when a fix is released. Credit in the advisory
is yours if you want it.

## Supported versions

Cadence has no stable release yet. Fixes go to `main` and into the next
tagged version. Only the latest tag and `main` are supported.

## What is in scope

Anything in this repository, and especially the parts that face the network
or read outside input:

| Area | Code |
|---|---|
| The library server: listener, HTTP parser, endpoints, limits | `Sources/CadenceServer` |
| Pairing, paired devices, the server's certificate and key | `Sources/CadenceServer`, `Sources/CadenceCore/Pairing` |
| The client library the iOS app and the Mac app use | `Sources/CadenceRemote` |
| The Mac app as a client: pairing links, the stored key | `Sources/Cadence/RemoteLibrary.swift` |
| Reading tags and audio from files in the library | `Sources/CadenceLibrary`, `Sources/CadenceAudio` |
| Stored credentials (Last.fm, Spotify) | `Sources/Cadence/KeychainStore.swift` |

Third-party code (GRDB, SFBAudioEngine and the decoders it bundles) is in
scope where Cadence's use of it is the problem. A flaw in the library itself
is better reported to its own project; tell us as well if Cadence is exposed.

## Threat model for library sharing

Sharing lets a Mac serve its music library to Cadence on a phone over the
local network. It is the part of Cadence built to be safe on a network you
do not trust, such as a café or office Wi-Fi.

**The attacker** is anyone on the same network as the Mac: able to see and
send traffic, connect to any port, answer in the Mac's place, and publish
Bonjour announcements. They have not paired, and they cannot look at the
Mac's screen.

**What sharing protects**

- The library: which music is on the Mac, and the files themselves.
- The paths and folder names where the music lives.
- Each paired device's API key, and the Mac's TLS private key.

**What sharing promises**

- **Off until switched on.** Sharing is off by default, the title bar shows
  when it is on, and switching it off closes the listener.
- **Nothing without a key.** Every library endpoint needs a paired device's
  key. There are no user names or passwords to guess; a missing key and a
  wrong key get the same answer. The only endpoint without a key says which
  sign-in methods exist and nothing else.
- **Read-only.** No endpoint changes, deletes or rescans anything. The one
  request that changes anything, `POST /pair`, can only add a paired device,
  and only while the user has a pairing code on screen.
- **Pairing cannot be intercepted.** The QR code carries the Mac's certificate
  fingerprint. The phone checks it before it sends the one-time token, so
  something answering in the Mac's place never sees the token. The token works
  once, expires after five minutes and allows five attempts. Typed codes, which
  could not carry a fingerprint, are switched off. Another Mac pairs with the
  link the QR code holds, copied rather than scanned: the same fingerprint,
  the same token. A link opened from outside Cadence is shown for the user to
  confirm before anything is sent.
- **Encrypted and pinned.** All traffic is TLS 1.3 to a certificate the phone
  pinned at pairing. Release builds contain no plain-HTTP listener. A client
  that does not pin cannot connect at all.
- **Keys are per device, random and revocable.** 256 bits from the system
  generator. The Mac stores only their SHA-256, in a file only the user can
  read. The client library never writes a key anywhere; the iOS app and a
  paired Mac keep it in the Keychain, for this device only. Revoking a device takes effect on its next
  request. Keys are never logged.
- **No paths on the wire.** Requests name songs, albums and artwork by opaque
  ids, never by path. No part of a request is joined to a directory, and a file
  swapped for a link or a directory is refused.
- **Bounded.** Request size, header count, body size, open connections, time
  to send a request, streams per device and stalled readers all have limits.
  Failed sign-ins are limited per address. The full table is in
  [docs/library-server.md](docs/library-server.md#limits).
- **The announcement says nothing.** Bonjour publishes a name, a type and a
  port, with no TXT record.

**Known limitations**

- **The server's private key can be exported by Cadence itself on macOS 14
  and 15.** It is created as not extractable, which macOS 26 enforces and
  earlier versions ignore for a key made this way. It is never written to a
  file, and the keychain still guards it from other programs.
- **A paired device is trusted with the whole library.** There is no
  per-folder sharing, and a paired device's requests are not rate limited
  beyond the stream and connection limits.
- **If the paired-devices file cannot be rewritten when a device is revoked**,
  the device is refused until Cadence quits but would be accepted after a
  relaunch. The app reports the failure when it happens.
- **A copied pairing link pairs whoever opens it first**, until it is used or
  expires. The copy is marked concealed so clipboard managers that honour the
  convention skip it, but it can still reach Universal Clipboard or a chat
  history. Close the code once the other Mac has paired.
- **Being found is not being trusted.** Anyone on the network can see that a
  Cadence server is there. They get a TLS handshake and nothing more.

**Out of scope**

- Someone who already controls the Mac's user account, or a paired device.
- Someone who can see the Mac's screen while a pairing code is showing.
- A paired device reading the library, which is what pairing grants.
- Reaching the Mac from outside the local network; Cadence does not offer it.

The decisions behind each of these, and the tests that hold them, are
recorded in [docs/library-server.md](docs/library-server.md).
