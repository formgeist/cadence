#!/bin/bash
#
# Assembles Cadence.app from the SwiftPM build product.
#
# There is no Xcode on this machine and therefore no .xcodeproj, but an .app is
# just a directory with a known shape — and building one by hand unblocks
# everything that needs a real bundle identity: Now Playing and media keys, the
# app sandbox, security-scoped bookmarks, and window restoration.
#
# It also produces the layout the LGPL components require — lame, mpg123,
# libsndfile and tta are embedded as dynamic frameworks rather than merged into
# the binary — and ships every component's licence text alongside them.
#
# Replace with a real Xcode target when one exists; nothing here is precious.

set -euo pipefail

CONFIG="${CONFIG:-debug}"
APP="${APP:-build/Cadence.app}"
BUNDLE_ID="${BUNDLE_ID:-com.formgeist.cadence}"
VERSION="${VERSION:-0.1.0}"
ICONSET="${ICONSET:-Icon/AppIcon.iconset}"
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

# The licence texts. LGPL components have to ship theirs, and the BSD ones ask
# for their notice to be reproduced in the material shipped alongside a binary,
# which for an app is the bundle. Copied rather than fetched at build time: a
# build that needs the network to be compliant is one that silently stops being
# compliant offline. See Licences/README.md for what each one covers.
mkdir -p "$APP/Contents/Resources/Licences"
cp Licences/*.txt Licences/README.md "$APP/Contents/Resources/Licences/"

# The font licences live beside the fonts they cover, not in Licences/, so they
# stay next to what they license in the source tree. They join the rest here.
cp Sources/Cadence/Resources/OFL-*.txt "$APP/Contents/Resources/Licences/"

# The icon. An asset catalog would need actool, which is Xcode's; .icns is the
# format that predates it and iconutil ships with Command Line Tools, so the
# .iconset in Icon/ stays the source and the .icns is a build product.
if [ -d "$ICONSET" ]; then
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_KEY='<key>CFBundleIconFile</key>              <string>AppIcon</string>'
else
    echo "No iconset at $ICONSET — bundling without an icon." >&2
    ICON_KEY=''
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Cadence</string>
    <key>CFBundleDisplayName</key>           <string>Cadence</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>            <string>Cadence</string>
    $ICON_KEY
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>14.0</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><true/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.music</string>

    <!-- The drag type for tracks moving onto a playlist. Declared so the
         identifier UTType(exportedAs:) forms in PlaylistActions.swift is a
         real one rather than a type the system invents per launch. Spelled
         out rather than built from $BUNDLE_ID: the Swift side is a literal,
         and an overridden bundle id must not silently split the two. -->
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>   <string>com.formgeist.cadence.track-ids</string>
            <key>UTTypeDescription</key>  <string>Cadence Tracks</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict/>
        </dict>
    </array>
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
# Guarded expansion: bash 3.2 is what macOS ships, and there an empty array
# expanded as "${a[@]}" under `set -u` is an unbound variable rather than
# nothing at all — which is why SANDBOX=0 could not build.
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none \
    ${ENTITLEMENT_ARGS[@]+"${ENTITLEMENT_ARGS[@]}"} "$APP"

codesign --verify --deep --strict "$APP" && echo "signature OK"
echo "$APP ready"
