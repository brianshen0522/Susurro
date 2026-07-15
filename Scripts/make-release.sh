#!/bin/bash
# Builds a release, zips it, signs it with the Sparkle EdDSA key (from your
# login keychain), and regenerates appcast.xml. Everything lands in
# releases/.
#
# Publishing a release afterwards:
#   1. Upload releases/Susurro-<version>.zip to a GitHub Release
#   2. Commit the updated appcast.xml to the repo's main branch
#
# TODO before distributing binaries widely:
#   - Sign with a Developer ID certificate and notarize the zip
#     (xcrun notarytool submit … --wait), or Gatekeeper will block users.
set -euo pipefail

GITHUB_REPO="brianshen0522/Susurro"
CHANNEL="beta"
# Self-signed identity in the login keychain. Signing every release with the
# SAME certificate keeps the app's TCC identity stable, so users keep their
# Accessibility/Microphone grants across updates. Swap for a Developer ID
# identity when one exists.
SIGN_IDENTITY="Susurro Release Signing"

cd "$(dirname "$0")/.."

if [ ! -x Vendor/ffmpeg ] || [ ! -x Vendor/yt-dlp ]; then
    echo "Vendor binaries missing — running fetch-vendor.sh first…"
    ./Scripts/fetch-vendor.sh
fi

if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "error: signing identity \"$SIGN_IDENTITY\" not found in the keychain." >&2
    echo "Create a self-signed code-signing certificate with that name first." >&2
    exit 1
fi

VERSION=$(xcodebuild -project Susurro.xcodeproj -scheme Susurro -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')
echo "Building Susurro $VERSION (channel: $CHANNEL, identity: $SIGN_IDENTITY)…"

# Build in the default (Xcode-shared) DerivedData so SwiftPM only ever
# resolves packages in one place — a second resolution corrupts the binary
# artifact cache.
xcodebuild -project Susurro.xcodeproj -scheme Susurro -configuration Release \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    DEVELOPMENT_TEAM="" \
    build | grep -E "error:|warning: code sign|BUILD" || true

PRODUCTS_DIR=$(xcodebuild -project Susurro.xcodeproj -scheme Susurro -configuration Release \
    -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')
APP="$PRODUCTS_DIR/Susurro.app"
[ -d "$APP" ] || { echo "error: build failed, $APP not found" >&2; exit 1; }

echo "Verifying signature…"
codesign --verify --deep --strict "$APP"
codesign -d -r- "$APP" 2>&1 | grep "designated" | head -1

mkdir -p releases
ZIP="releases/Susurro-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "Archived: $ZIP"

GENERATE_APPCAST=$(find ~/Library/Developer/Xcode/DerivedData/Susurro-*/SourcePackages/artifacts/sparkle/Sparkle/bin \
    -maxdepth 1 -name generate_appcast 2>/dev/null | head -1)
[ -n "$GENERATE_APPCAST" ] || { echo "error: generate_appcast not found — resolve SPM packages in Xcode first" >&2; exit 1; }

"$GENERATE_APPCAST" \
    --channel "$CHANNEL" \
    --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$VERSION/" \
    releases/

cp releases/appcast.xml appcast.xml

# Human-facing DMG (Sparkle updates use the zip). dist/ keeps it away from
# generate_appcast's scan of releases/.
mkdir -p dist
DMG="dist/Susurro-$VERSION.dmg"
rm -f "$DMG"
echo "Creating DMG…"
create-dmg \
    --volname "Susurro" \
    --background "Assets/dmg-background.png" \
    --window-size 660 440 \
    --icon-size 128 \
    --text-size 13 \
    --icon "Susurro.app" 165 200 \
    --app-drop-link 495 200 \
    --hide-extension "Susurro.app" \
    --no-internet-enable \
    "$DMG" \
    "$APP"
codesign --force --sign "$SIGN_IDENTITY" "$DMG"

echo ""
echo "Done. Next steps:"
echo "  1. gh release create v$VERSION $DMG $ZIP --title \"Susurro $VERSION\" --prerelease"
echo "  2. git add appcast.xml && git commit -m \"Release $VERSION\" && git push"
