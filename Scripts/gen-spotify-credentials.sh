#!/bin/bash
#
# Writes Sources/Cadence/SpotifyCredentials.swift if it is missing.
#
# Git-ignored, like the Last.fm credentials: it carries the Spotify client id
# a build signs in with. A fresh checkout gets an empty id — the app builds and
# runs, and Import Spotify Playlist says the build has no Spotify app.
#
# To work on the importer, create an app at
# https://developer.spotify.com/dashboard, add the redirect URI
# cadence://spotify-callback, tick "Web API", and paste the client id in.
# Only the id: sign-in uses PKCE, so there is no client secret to keep.
#
# An existing file is left untouched.

set -euo pipefail

cd "$(dirname "$0")/.."
DEST="Sources/Cadence/SpotifyCredentials.swift"

if [ -f "$DEST" ]; then
    exit 0
fi

cat > "$DEST" <<'SWIFT'
import Foundation

/// The Spotify app the playlist importer signs in through. This file is
/// **git-ignored and generated** — `Scripts/gen-spotify-credentials.sh`
/// writes it with an empty id on a fresh checkout.
///
/// Create an app at <https://developer.spotify.com/dashboard>, register the
/// redirect URI `cadence://spotify-callback`, and put its client id here.
/// There is no secret: sign-in uses PKCE.
enum SpotifyCredentials {
    static let clientID = ""
}
SWIFT

echo "Generated $DEST with an empty client id."
