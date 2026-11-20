#!/bin/bash
# Build the Cadence executable and run it with the arguments given, signed with
# the local signing certificate when there is one.
#
#   Scripts/run-dev.sh [--release] [arguments for Cadence...]
#
# Why not `swift run`: SwiftPM signs what it links ad-hoc, and an ad-hoc
# signature is the hash of that exact binary. The app reads the keychain at
# launch, so after every rebuild macOS treats it as a new program and stops at
# a password prompt. For a harness run from a script, such as `make serve` or
# `make scan`, that prompt is a hang: the process waits on a dialog nobody is
# looking at and prints nothing.
#
# A real certificate gives every build the same identity, so "Always Allow" is
# asked once and sticks. This is the same certificate `make app` uses, chosen
# by signing-identity.sh; CONTRIBUTING.md, "A stable signature for local
# builds", says more. Without one this script behaves exactly as `swift run`.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=debug
if [ "${1:-}" = "--release" ]; then
    CONFIG=release
    shift
fi

SIGN_IDENTITY="${SIGN_IDENTITY:-$(Scripts/signing-identity.sh)}"
# The same identifier as the assembled app, so the keychain sees one program
# whether it was started from the bundle or from here.
BUNDLE_ID="${BUNDLE_ID:-com.formgeist.cadence}"

swift build -c "$CONFIG" --product Cadence
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/Cadence"

if [ "$SIGN_IDENTITY" != "-" ]; then
    # Only when the build produced a new binary: one already signed by this
    # certificate is left alone.
    if ! codesign -dv "$BINARY" 2>&1 | grep -q "^Identifier=$BUNDLE_ID\$"; then
        codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
            --timestamp=none "$BINARY" 2>/dev/null
    fi
fi

exec "$BINARY" "$@"
