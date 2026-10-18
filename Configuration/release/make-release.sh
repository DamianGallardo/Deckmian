#!/bin/bash
# Builds a universal (Apple Silicon + Intel) Release of Deckmian and packages it as a DMG.
#
# Usage: ./Configuration/release/make-release.sh
# Output: dist/Deckmian-<version>.dmg
#
# The app is signed with the local "Deckmian Local Signing" identity (see README). It is not
# notarized, so users must allow it once in System Settings > Privacy & Security ("Open Anyway").
# Signing every release with the same identity keeps users' macOS permissions across updates.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/build/release"
DIST_DIR="$ROOT/dist"
APP_NAME="Deckmian"

cd "$ROOT"

if pgrep -xq "$APP_NAME"; then
    echo "Quit $APP_NAME before building a release." >&2
    exit 1
fi

echo "==> Building universal Release"
mkdir -p "$BUILD_DIR"
xcodebuild -project Deckmian.xcodeproj -scheme Deckmian -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    build > "$BUILD_DIR.log" 2>&1 || {
        echo "Build failed. See $BUILD_DIR.log" >&2
        grep -n "error:" "$BUILD_DIR.log" | head -20 >&2 || true
        exit 1
    }

APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

echo "==> Verifying signature"
codesign --verify --deep --strict "$APP"
lipo -archs "$APP/Contents/MacOS/$APP_NAME"

echo "==> Packaging DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/Configuration/release/How to open Deckmian.txt" "$STAGING/"

mkdir -p "$DIST_DIR"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null

echo "==> Done"
echo "Version: $VERSION ($BUILD)"
echo "DMG:     $DMG"
echo "SHA-256: $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
