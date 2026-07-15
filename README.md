<h1 align="center">Susurro</h1>

<p align="center">
  <em>susurro (Spanish) — a whisper.</em>
</p>

<p align="center">
  Local-first dictation and transcription for macOS. Hold a key, speak, and
  the text lands in whatever app you're using — no cloud required.
</p>

---

## About

Susurro replaces macOS's built-in dictation with something faster, more
accurate, and entirely private: speech recognition runs on your Mac's Neural
Engine via Whisper, so your voice never leaves the machine. Hold the hotkey,
talk, let go — the transcribed text is typed directly into whatever app has
focus, whether that's a chat box, a code editor, or an email draft. While you
speak, any music or video playing on your Mac pauses automatically and picks
back up when the words land.

Beyond live dictation, Susurro is a subtitle workshop. Feed it a lecture
recording, a downloaded movie in any container format, or just paste a
YouTube or M3U8 link — it downloads the media, transcribes it with segment
timestamps, translates the result on-device into as many languages as you
want, and writes `.srt` files (original, translated, or bilingual) right next
to the video. Long jobs run in a queue with real progress bars, and
everything you've transcribed stays searchable in the app's library.

---

## Features

**Dictation**
- Hold a global hotkey (default **Fn**, configurable) to record; release to
  transcribe and type the result straight into the focused app
- Fully on-device speech-to-text via [WhisperKit](https://github.com/argmaxinc/WhisperKit)
  (CoreML / Apple Neural Engine); optional OpenAI API mode
- Native-feeling floating overlay with a live waveform while you speak
- Automatically pauses Music / Spotify / VLC while you dictate and resumes
  them afterwards
- Searchable dictation history with one-click copy

**File & URL transcription**
- Drop in audio or video files — every common format works (native
  AVFoundation decode, with a bundled FFmpeg fallback for mkv/webm/ogg/…)
- Paste a YouTube or M3U8 URL: Susurro downloads the video and transcribes it
- Export subtitles as **SRT**, WebVTT, or plain text (UTF-8 with BOM, so CJK
  text survives every player)
- On-device subtitle translation (Apple Translation) into multiple languages
  at once, with translated-only and **bilingual** SRT output
- Byte-accurate download progress, per-stage progress bars, cancellable jobs

**Model management**
- Download, load, unload, and test Whisper models from the Settings page
- Pick a default model that loads automatically at launch
- Live RAM usage for the loaded model

## Updates

> **Susurro is currently in beta** (0.x versions).

The app updates itself via [Sparkle](https://sparkle-project.org): it checks
the appcast in this repo, and new releases install with one click from the
built-in update window. Settings → Updates has a manual "Check for Updates"
button, an automatic-check toggle, and a beta-channel opt-out for when
stable releases exist.

Maintainers cut a release with `Scripts/make-release.sh` (build → zip →
EdDSA-sign → regenerate `appcast.xml`), upload the zip to a GitHub Release,
and commit the updated appcast.

## Requirements

- macOS 26.5 or later, Apple Silicon
- ~500 MB–3 GB disk per Whisper model (downloaded on demand)

## Building

```sh
git clone https://github.com/brianshen0522/Susurro.git
cd Susurro
./Scripts/fetch-vendor.sh   # downloads the bundled ffmpeg & yt-dlp binaries
open Susurro.xcodeproj      # build & run the Susurro scheme with Xcode 26+
```

### Bundled tools (`Vendor/`)

Susurro bundles two prebuilt command-line tools inside the app so users
never have to install anything themselves:

- **ffmpeg** (~65 MB, static arm64) — decodes formats AVFoundation can't
  (mkv, webm, ogg, opus, …) and downloads M3U8/HLS streams
- **yt-dlp** (~38 MB, standalone) — downloads media from YouTube and other
  sites

These binaries are **not committed to the repo** — they would add ~100 MB of
history, and keeping the GPL-licensed ffmpeg binary out of the MIT-licensed
source tree keeps the licensing boundary clean. Instead,
`Scripts/fetch-vendor.sh` downloads them into `Vendor/` (gitignored), and
the "Copy Bundled Tools" build phase copies them into
`Susurro.app/Contents/MacOS/` and code-signs them with the app.

Notes:

- Run the script **once after cloning**. If you skip it, the build fails at
  the copy phase with a "file not found: Vendor/ffmpeg" error.
- Re-run with `--force` to update both tools to their latest releases —
  worth doing periodically for yt-dlp, which needs updates to keep up with
  site changes.
- At runtime, Susurro prefers the bundled copies but falls back to Homebrew
  (`/opt/homebrew/bin`) or `PATH` if they're missing, so `brew install
  ffmpeg yt-dlp` also works during development.

## Permissions

Susurro asks for these on first use:

| Permission | Why |
|---|---|
| Microphone | Recording your voice for dictation |
| Accessibility | The global hotkey (CGEventTap) and typing text into other apps |
| Automation (Apple Events) | Pausing/resuming Music, Spotify, and VLC during dictation |

Everything runs locally. Nothing leaves your machine unless you explicitly
choose the OpenAI API mode.

## Acknowledgments

- [MacParakeet](https://github.com/moona3k/macparakeet) — Susurro's
  file-transcription workflow (media file → local Whisper → subtitles) was
  inspired by MacParakeet's design. Susurro is an independent implementation
  and shares no code with it.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) (MIT) — the on-device
  speech-to-text engine.
- [FFmpeg](https://ffmpeg.org) (GPL build, bundled) and
  [yt-dlp](https://github.com/yt-dlp/yt-dlp) (Unlicense, bundled) — media
  decoding and downloading, invoked as subprocesses.

## License

Susurro is released under the [MIT License](LICENSE).

The bundled FFmpeg binary is a separate, GPL-licensed program aggregated with
the app — see [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for details
and source availability.
