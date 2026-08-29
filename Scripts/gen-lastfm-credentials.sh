#!/bin/bash
#
# Writes Sources/Cadence/LastFMCredentials.swift if it is missing.
#
# The file is git-ignored: it carries a Last.fm API key and shared secret, and
# this repository is public. A fresh checkout has no copy, so this generates one
# with empty values — the app builds and runs, and Preferences shows scrobbling
# as unavailable (LastFMScrobbler.isConfigured is false on an empty key).
#
# To work on scrobbling, register an app at
# https://www.last.fm/api/account/create and fill the two fields in — your copy
# stays local because git ignores it. Official release builds overwrite the file
# with real values injected from CI secrets before building.
#
# An existing file is left untouched: a maintainer's filled-in copy, or one a
# release job has already written, must win over this stub.

set -euo pipefail

cd "$(dirname "$0")/.."
DEST="Sources/Cadence/LastFMCredentials.swift"

if [ -f "$DEST" ]; then
    exit 0
fi

cat > "$DEST" <<'SWIFT'
import Foundation

/// Last.fm API credentials, compiled in. This file is **git-ignored and
/// generated** — `Scripts/gen-lastfm-credentials.sh` writes it with empty
/// values on a fresh checkout, and release builds overwrite it with real
/// values from CI secrets.
///
/// To work on scrobbling locally, register an application at
/// <https://www.last.fm/api/account/create> and put the key and shared secret
/// here. Your copy stays local because git ignores the file.
///
/// With both fields empty, `LastFMScrobbler.isConfigured` is false and the
/// Preferences window shows scrobbling as unavailable rather than offering a
/// flow that cannot complete — a fresh clone still builds and runs.
enum LastFMCredentials {
    static let apiKey = ""
    static let sharedSecret = ""

    static var isConfigured: Bool { !apiKey.isEmpty && !sharedSecret.isEmpty }
}
SWIFT

echo "Generated $DEST with empty credentials."
