import AppKit
import SwiftUI

/// Custom About window — a proper page rather than the system's tiny panel.
struct AboutView: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        if let build, build != short {
            return "\(short) (\(build))"
        }
        return short
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("Susurro")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))

                Text(String(localized: "about.tagline", defaultValue: "susurro (Spanish) — a whisper."))
                    .font(.system(size: 13))
                    .italic()
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(String(localized: "about.version", defaultValue: "Version \(version)"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "about.beta", defaultValue: "BETA"))
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 32)

            VStack(alignment: .leading, spacing: 14) {
                Text(String(
                    localized: "about.body.dictation",
                    defaultValue: """
                    Susurro is local-first dictation and transcription for macOS. \
                    Hold a key, speak, and your words are typed into whatever app \
                    you're using — recognized entirely on your Mac by Whisper, with \
                    nothing sent to the cloud. While you dictate, music and video \
                    playing on your Mac pause automatically and resume when the \
                    words land.
                    """
                ))

                Text(String(
                    localized: "about.body.files",
                    defaultValue: """
                    It is also a subtitle workshop: drop in audio or video in any \
                    format, or paste a YouTube or M3U8 link. Susurro downloads the \
                    media, transcribes it with timestamps, translates on-device \
                    into as many languages as you like, and exports SRT — original, \
                    translated, or bilingual.
                    """
                ))
            }
            .font(.system(size: 12.5))
            .lineSpacing(3)
            .foregroundStyle(.primary.opacity(0.85))
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            Divider()
                .padding(.horizontal, 32)

            VStack(spacing: 6) {
                Text(String(
                    localized: "about.credits",
                    defaultValue: "Built with WhisperKit, FFmpeg, and yt-dlp."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Text(String(
                    localized: "about.license",
                    defaultValue: "Open source under the MIT License."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)

                Text("© 2026 Brian Shen")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 18)
        }
        .frame(width: 460)
        .multilineTextAlignment(.leading)
    }
}
