#!/bin/bash
#
# Assembles Cadence.app from the SwiftPM build product.
#
# There is no Xcode on this machine and therefore no .xcodeproj, but an .app is
# just a directory with a known shape — and building one by hand unblocks
# everything that needs a real bundle identity: Now Playing and media keys, the
# app sandbox, security-scoped bookmarks, and window restoration.
#
# It also produces the layout the LGPL components require: lame, mpg123 and
# musepack are embedded as dynamic frameworks rather than merged into the
# binary.
#
# Replace with a real Xcode target when one exists; nothing here is precious.

set -euo pipefail

CONFIG="${CONFIG:-debug}"
APP="${APP:-build/Cadence.app}"
BUNDLE_ID="${BUNDLE_ID:-com.formgeist.cadence}"
VERSION="${VERSION:-0.1.0}"
# Ad-hoc by default. Set SIGN_IDENTITY to a Developer ID for distribution.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILT=$(swift build -c "$CONFIG" --show-bin-path)
BINARY="$BUILT/Cadence"

if [ ! -x "$BINARY" ]; then
    echo "No binary at $BINARY — run 'swift build' first." >&2
    exit 1
fi

echo "Assembling $APP from $CONFIG"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BINARY" "$APP/Contents/MacOS/Cadence"

# SwiftPM resource bundles (fonts, and GRDB's) sit beside the binary and are
# found relative to it.
for bundle in "$BUILT"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# The decoder frameworks, from whichever xcframework slice targets macOS.
for framework in $(find .build/artifacts -type d -name "*.framework" -path "*macos*"); do
    cp -R "$framework" "$APP/Contents/Frameworks/"
done

# The binary looks for them on @rpath; point that at the bundle.
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP/Contents/MacOS/Cadence" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Cadence</string>
    <key>CFBundleDisplayName</key>           <string>Cadence</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>            <string>Cadence</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.music</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" > /dev/null

# The sandbox is what PLAN.md §5 requires, and answering its sample-rate
# question needs a genuinely sandboxed build. Set SANDBOX=0 to test the
# difference.
if [ "${SANDBOX:-1}" = "1" ]; then
    cat > build/cadence.entitlements <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>                        <true/>
    <key>com.apple.security.files.user-selected.read-only</key>       <true/>
    <!-- Without this the user's music folder is inaccessible on the second
         launch, and there is no workaround. PLAN.md §5. -->
    <key>com.apple.security.files.bookmarks.app-scope</key>           <true/>
</dict>
</plist>
ENTITLEMENTS
    ENTITLEMENT_ARGS=(--entitlements build/cadence.entitlements)
else
    ENTITLEMENT_ARGS=()
fi

# Frameworks first, then the app: nested code must be signed before its host.
for framework in "$APP/Contents/Frameworks"/*.framework; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$framework" 2>/dev/null
done
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    "${ENTITLEMENT_ARGS[@]}" "$APP"

codesign --verify --deep --strict "$APP" && echo "signature OK"
echo "$APP ready"
