# Third-Party Licenses

Susurro itself is MIT-licensed (see [LICENSE](LICENSE)). It depends on and
bundles the following third-party software.

## WhisperKit

- License: MIT
- Source: <https://github.com/argmaxinc/WhisperKit>
- Copyright (c) 2024 Argmax, Inc.

Linked as a Swift Package dependency; provides the on-device Whisper
speech-to-text engine.

## Sparkle

- License: MIT
- Source: <https://github.com/sparkle-project/Sparkle>
- Copyright (c) 2006-2013 Andy Matuschak and contributors

Linked as a Swift Package dependency; provides the in-app update mechanism.

## FFmpeg (bundled binary)

- License: **GPL-3.0** (this build enables GPL components such as libx264/libx265)
- Source: <https://ffmpeg.org> — build by Martin Riedl, <https://ffmpeg.martin-riedl.de>
  (build scripts and configuration published at that site)
- Bundled at `Susurro.app/Contents/MacOS/ffmpeg` (from `Vendor/ffmpeg` in this repo)

FFmpeg is invoked strictly as a separate subprocess and is not linked into
Susurro; it is aggregated alongside the MIT-licensed app. The GPL applies to
the FFmpeg binary itself: its complete corresponding source is available from
the links above. You may replace the bundled binary with your own build (an
LGPL configuration also works for Susurro's usage — audio decode and HLS
stream copy).

## yt-dlp (bundled binary)

- License: Unlicense (public domain)
- Source: <https://github.com/yt-dlp/yt-dlp>
- Bundled at `Susurro.app/Contents/MacOS/yt-dlp` (from `Vendor/yt-dlp` in this repo)

Invoked as a separate subprocess for downloading media from URLs.
