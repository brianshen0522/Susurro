import AppKit
import Foundation

/// Pauses whichever media apps are playing when dictation starts and
/// resumes exactly those afterwards. Control goes over Apple events
/// (osascript) to the common scriptable players; browser playback cannot be
/// controlled this way.
@MainActor
final class MediaPlaybackController {
    private enum Player: String, CaseIterable {
        case music
        case spotify
        case vlc

        var bundleID: String {
            switch self {
            case .music: return "com.apple.Music"
            case .spotify: return "com.spotify.client"
            case .vlc: return "org.videolan.vlc"
            }
        }

        var appName: String {
            switch self {
            case .music: return "Music"
            case .spotify: return "Spotify"
            case .vlc: return "VLC"
            }
        }

        /// Pauses only if currently playing; prints "was-playing" so the
        /// caller knows whether to resume later.
        var pauseScript: String {
            switch self {
            case .music, .spotify:
                return """
                tell application "\(appName)"
                    if player state is playing then
                        pause
                        return "was-playing"
                    end if
                end tell
                return "no"
                """
            case .vlc:
                // VLC's `play` command is a toggle.
                return """
                tell application "VLC"
                    if playing then
                        play
                        return "was-playing"
                    end if
                end tell
                return "no"
                """
            }
        }

        var resumeScript: String {
            switch self {
            case .music, .spotify:
                return "tell application \"\(appName)\" to play"
            case .vlc:
                return """
                tell application "VLC"
                    if not playing then play
                end tell
                """
            }
        }
    }

    private var pausedPlayers: [Player] = []
    /// Serializes pause/resume so a quick record-release cannot let the
    /// resume overtake a pause that is still in flight.
    private var chain: Task<Void, Never>?

    func pauseNowPlaying() {
        chain = Task { [previousLink = chain] in
            await previousLink?.value
            var paused: [Player] = []
            for player in Player.allCases where Self.isRunning(player.bundleID) {
                if await Self.runScript(player.pauseScript) == "was-playing" {
                    paused.append(player)
                }
            }
            pausedPlayers = paused
        }
    }

    func resumePaused() {
        chain = Task { [previousLink = chain] in
            await previousLink?.value
            for player in pausedPlayers where Self.isRunning(player.bundleID) {
                _ = await Self.runScript(player.resumeScript)
            }
            pausedPlayers = []
        }
    }

    /// Scripts must only target running apps — referencing an app that is
    /// not installed makes AppleScript ask the user to locate it.
    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func runScript(_ source: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } catch {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
