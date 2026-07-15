#!/bin/bash
# Downloads the prebuilt binaries Susurro bundles into the app
# (Vendor/ffmpeg and Vendor/yt-dlp). Run once after cloning, before the
# first Xcode build. Pass --force to re-download and update to the latest
# versions.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Vendor

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ "$(uname -m)" != "arm64" ]; then
    echo "warning: these binaries are arm64-only; Susurro targets Apple Silicon." >&2
fi

fetch_ffmpeg() {
    if [ -x Vendor/ffmpeg ] && [ "$FORCE" -eq 0 ]; then
        echo "Vendor/ffmpeg already present — skipping (use --force to update)"
        return
    fi
    echo "Downloading ffmpeg (static arm64, GPL build by martin-riedl.de)…"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    curl -fL --progress-bar -o "$tmp/ffmpeg.zip" \
        "https://ffmpeg.martin-riedl.de/redirect/latest/macos/arm64/release/ffmpeg.zip"
    unzip -oq "$tmp/ffmpeg.zip" -d "$tmp"
    mv "$tmp/ffmpeg" Vendor/ffmpeg
    xattr -c Vendor/ffmpeg
    chmod +x Vendor/ffmpeg
    Vendor/ffmpeg -version | head -1
}

fetch_ytdlp() {
    if [ -x Vendor/yt-dlp ] && [ "$FORCE" -eq 0 ]; then
        echo "Vendor/yt-dlp already present — skipping (use --force to update)"
        return
    fi
    echo "Downloading yt-dlp (standalone macOS build)…"
    curl -fL --progress-bar -o Vendor/yt-dlp \
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"
    xattr -c Vendor/yt-dlp
    chmod +x Vendor/yt-dlp
    echo "yt-dlp $(Vendor/yt-dlp --version)"
}

fetch_ffmpeg
fetch_ytdlp
echo "Done. Vendor binaries are ready; build the Susurro scheme in Xcode."
