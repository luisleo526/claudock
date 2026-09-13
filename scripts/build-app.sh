#!/bin/bash
set -euo pipefail
umask 077

# Build one local architecture. Run separately on Apple Silicon and Intel for releases.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT=${1:-"$ROOT/dist"}

if [ "$#" -gt 1 ]; then
    echo "Usage: scripts/build-app.sh [output-directory]" >&2
    exit 2
fi
if [ "$(uname -s)" != Darwin ]; then
    echo "Claudock requires macOS to build." >&2
    exit 1
fi
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

mkdir -p "$OUTPUT"
OUTPUT=$(cd "$OUTPUT" && pwd)
APP="$OUTPUT/Claudock.app"
if [ -e "$APP" ] || [ -L "$APP" ]; then
    echo "Refusing to overwrite $APP. Choose another output directory or move that app first." >&2
    exit 1
fi

cd "$ROOT"
xcrun swift build -c release
BINARY_DIR=$(xcrun swift build -c release --show-bin-path)
mkdir -p "$ROOT/.build"
# Sign outside the checkout so cloud-synced source folders cannot attach
# Finder metadata to the bundle between cleanup and signature verification.
STAGE=$(mktemp -d "${TMPDIR:-/private/tmp}/claudock-app.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
BUNDLE="$STAGE/Claudock.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY_DIR/ClaudockApp" "$BUNDLE/Contents/MacOS/ClaudockApp"
cp "$BINARY_DIR/claudock" "$BUNDLE/Contents/MacOS/claudock"
cp "$ROOT/LICENSE" "$BUNDLE/Contents/Resources/License.txt"
chmod 755 "$BUNDLE/Contents/MacOS/ClaudockApp" "$BUNDLE/Contents/MacOS/claudock"
# Remove local object-file paths from release debug maps before signing.
# Keep executable code, Swift metadata, and exported symbols intact.
xcrun strip -S "$BUNDLE/Contents/MacOS/ClaudockApp" "$BUNDLE/Contents/MacOS/claudock"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>Claudock</string>
    <key>CFBundleExecutable</key><string>ClaudockApp</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>io.github.claudeusage.ClaudeUsage</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Claudock</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.5.1</string>
    <key>CFBundleVersion</key><string>9</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Claudock contributors. MIT License.</string>
</dict>
</plist>
PLIST

xcrun swift -module-cache-path "$ROOT/.build/icon-module-cache" "$ROOT/scripts/make-icon.swift" "$STAGE/Claudock.iconset"
/usr/bin/iconutil -c icns "$STAGE/Claudock.iconset" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$BUNDLE/Contents/Info.plist"

# Normalize only the app's public resources; the staging parent remains private.
# A permissive caller umask must not produce a group/world-writable application.
chmod 755 "$BUNDLE" "$BUNDLE/Contents" "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
chmod 644 "$BUNDLE/Contents/Info.plist" "$BUNDLE/Contents/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/License.txt"

# Finder/sync metadata attached to newly built files can invalidate signing.
# Touch only disallowed metadata on our new bundle; preserve other attributes.
clear_signing_metadata() {
    /usr/bin/xattr -r -d com.apple.FinderInfo "$1" 2>/dev/null || true
    /usr/bin/xattr -r -d com.apple.ResourceFork "$1" 2>/dev/null || true
}
clear_signing_metadata "$BUNDLE"

IDENTITY=${CODE_SIGN_IDENTITY:--}
if [ "$IDENTITY" = "-" ]; then
    (umask 022; /usr/bin/codesign --force --sign - "$BUNDLE/Contents/MacOS/claudock")
    (umask 022; /usr/bin/codesign --force --sign - "$BUNDLE")
else
    (umask 022; /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE/Contents/MacOS/claudock")
    (umask 022; /usr/bin/codesign --force --options runtime --timestamp --sign "$IDENTITY" "$BUNDLE")
fi
/usr/bin/codesign --verify --strict --verbose=2 "$BUNDLE/Contents/MacOS/claudock"
/usr/bin/codesign --verify --strict --verbose=2 "$BUNDLE"

# Recheck before copying; never replace or merge an existing application bundle.
if [ -e "$APP" ] || [ -L "$APP" ]; then
    echo "Output appeared during the build; refusing to overwrite $APP." >&2
    exit 1
fi
mv -n "$BUNDLE" "$OUTPUT/"
if [ -d "$BUNDLE" ]; then
    echo "Could not move the application into $OUTPUT." >&2
    exit 1
fi
# A file provider may attach FinderInfo when the bundle enters the destination.
clear_signing_metadata "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/claudock"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
echo "Built: $APP"
echo "Architecture: $(/usr/bin/lipo -archs "$APP/Contents/MacOS/ClaudockApp")"
if [ "$IDENTITY" = "-" ]; then
    echo "Signed ad hoc for local use. This build is not notarized."
fi
