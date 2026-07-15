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

cd "$(dirname "$0")/.."

if [ ! -x Vendor/ffmpeg ] || [ ! -x Vendor/yt-dlp ]; then
    echo "Vendor binaries missing — running fetch-vendor.sh first…"
    ./Scripts/fetch-vendor.sh
fi

VERSION=$(xcodebuild -project Susurro.xcodeproj -scheme Susurro -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/MARKETING_VERSION/ {print $2; exit}')
echo "Building Susurro $VERSION (channel: $CHANNEL)…"

xcodebuild -project Susurro.xcodeproj -scheme Susurro -configuration Release \
    -derivedDataPath build/DerivedData build | grep -E "error:|warning: code sign|BUILD" || true

APP="build/DerivedData/Build/Products/Release/Susurro.app"
[ -d "$APP" ] || { echo "error: build failed, $APP not found" >&2; exit 1; }

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
echo ""
echo "Done. Next steps:"
echo "  1. gh release create v$VERSION $ZIP --title \"Susurro $VERSION\" --prerelease"
echo "  2. git add appcast.xml && git commit -m \"Release $VERSION\" && git push"
