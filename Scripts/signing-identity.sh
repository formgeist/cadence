#!/bin/bash
# Prints the code-signing identity a local build should use, for
# make-app.sh and run-dev.sh to share.
#
# An ad-hoc signature is the hash of the exact binary, so every rebuild is a new
# app to the keychain: the Last.fm session key, the pairing with another Mac
# and the library server's TLS key all stop being readable after an update.
# Any real certificate gives rebuilds a stable identity instead. In order:
#
#   1. A self-signed certificate named LOCAL_IDENTITY ("Cadence Local Signing"),
#      the one CONTRIBUTING.md describes.
#   2. An "Apple Development" certificate, which anyone signed in to Xcode with
#      an Apple ID has. It is printed by its SHA-1 hash, which is unambiguous
#      even when there are several.
#   3. "-", ad-hoc, when there is neither.
#
# The self-signed certificate is untrusted, so identities are listed without -v.
set -euo pipefail

LOCAL_IDENTITY="${LOCAL_IDENTITY:-Cadence Local Signing}"
IDENTITIES=$(security find-identity -p codesigning 2>/dev/null || true)

if printf '%s\n' "$IDENTITIES" | grep -qF "\"$LOCAL_IDENTITY\""; then
    echo "$LOCAL_IDENTITY"
    exit 0
fi

# Lines look like:  1) <40 hex> "Apple Development: Name (TEAMID)"
DEVELOPMENT=$(printf '%s\n' "$IDENTITIES" \
    | awk '/"Apple Development: / { print $2; exit }')
if [ -n "$DEVELOPMENT" ]; then
    echo "$DEVELOPMENT"
    exit 0
fi

echo "-"
