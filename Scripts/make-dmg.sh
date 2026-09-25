#!/bin/bash
#
# Wraps an assembled Cadence.app in a drag-to-install disk image: the app beside
# a link to /Applications, the layout Finder users expect from a .dmg.
#
# The app inside is whatever make-app.sh produced, so it carries the same
# signature — ad-hoc unless SIGN_IDENTITY was set. An ad-hoc build installs and
# runs fine on the machine that built it (a local build is never quarantined),
# but is not something to hand to anyone else: Gatekeeper will refuse it there.
# Notarisation belongs with the Developer ID build, issue #8.

set -euo pipefail

APP="${APP:-build/Cadence.app}"
VERSION="${VERSION:-0.1.0}"
DMG="${DMG:-build/Cadence-$VERSION.dmg}"

if [ ! -d "$APP" ]; then
    echo "No app at $APP — run 'make app' first." >&2
    exit 1
fi

STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create \
    -volname "Cadence" \
    -srcfolder "$STAGING" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" > /dev/null

hdiutil verify "$DMG" > /dev/null && echo "$DMG ready"
