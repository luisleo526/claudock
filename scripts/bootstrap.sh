#!/bin/bash
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/.." && pwd)
fail() { echo "Claudock: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "This application requires macOS 14 or newer."
OS_VERSION=$(/usr/bin/sw_vers -productVersion)
[ "${OS_VERSION%%.*}" -ge 14 ] || fail "macOS $OS_VERSION is too old. Update to macOS 14 or newer."

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    fail "Building and testing from source needs full Xcode 16 or newer (the Command Line Tools alone do not include all test frameworks). Install Xcode from the Mac App Store, open it once to finish setup, then try again. If Xcode is in a custom location, set DEVELOPER_DIR to its Contents/Developer directory."
fi
SWIFT_VERSION=$(/usr/bin/xcrun swift --version)
SWIFT_MAJOR=$(echo "$SWIFT_VERSION" | /usr/bin/sed -n 's/.*Swift version \([0-9][0-9]*\).*/\1/p' | /usr/bin/head -n 1)
case "$SWIFT_MAJOR" in
    ''|*[!0-9]*) fail "Could not identify your Swift version. Open Xcode to finish its installation, then retry." ;;
esac
[ "$SWIFT_MAJOR" -ge 6 ] || fail "Swift 6 or newer is required. Update Xcode to version 16 or newer."

cd "$ROOT"
echo "Testing Claudock…"
/usr/bin/xcrun swift test
mkdir -p "$ROOT/dist"
# Each bootstrap uses a fresh directory and never overwrites a running app.
OUTPUT=$(mktemp -d "$ROOT/dist/Build.XXXXXX")
echo "Building Claudock…"
"$ROOT/scripts/build-app.sh" "$OUTPUT"
echo "Opening Claudock. You can move it to Applications after quitting it."
/usr/bin/open "$OUTPUT/Claudock.app"
