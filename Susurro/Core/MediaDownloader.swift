import Foundation

enum MediaDownloaderError: LocalizedError {
    case ytDlpNotFound
    case ffmpegNotFound
    case downloadFailed(String)
    case noOutputFile

    var errorDescription: String? {
        switch self {
        case .ytDlpNotFound:
            return String(
                localized: "download.ytDlpNotFound",
                defaultValue: "yt-dlp was not found. Install it with \"brew install yt-dlp\" and try again."
            )
        case .ffmpegNotFound:
            return String(
                localized: "download.ffmpegNotFound",
                defaultValue: "ffmpeg was not found. Install it with \"brew install ffmpeg\" and try again."
            )
        case .downloadFailed(let msg):
            return String(localized: "download.failed", defaultValue: "Download failed: \(msg)")
        case .noOutputFile:
            return String(localized: "download.noOutput", defaultValue: "The download finished but no video file was produced.")
        }
    }
}

/// Downloads remote media into a user-chosen folder. M3U8/HLS streams go
/// straight through ffmpeg; everything else (YouTube and most video sites)
/// goes through yt-dlp.
enum MediaDownloader {
    static func isHLSURL(_ url: URL) -> Bool {
        url.path.lowercased().hasSuffix(".m3u8")
            || url.absoluteString.lowercased().contains(".m3u8")
    }

    /// Downloads `url` into `folder` and returns the local video file URL.
    /// `progress` receives a fraction (0...1) when known, nil when the
    /// download has no measurable total (e.g. HLS streams).
    static func download(
        from url: URL,
        to folder: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        if isHLSURL(url) {
            return try await downloadHLS(from: url, to: folder, progress: progress)
        }
        return try await downloadWithYtDlp(from: url, to: folder, progress: progress)
    }

    static func findYtDlp() -> URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "yt-dlp") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/opt/local/bin/yt-dlp",
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates += envPath.split(separator: ":").map { "\($0)/yt-dlp" }
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    // MARK: - HLS (ffmpeg)

    private static func downloadHLS(
        from url: URL,
        to folder: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        guard let ffmpeg = AudioExtractor.findFFmpeg() else {
            throw MediaDownloaderError.ffmpegNotFound
        }

        let output = folder.appendingPathComponent(hlsOutputName(for: url))
        progress(nil)

        let result: ProcessResult
        do {
            result = try await runProcess(
                executable: ffmpeg,
                arguments: [
                    "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
                    "-i", url.absoluteString,
                    "-c", "copy",
                    output.path,
                ],
                onStdoutLine: nil
            )
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }

        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw MediaDownloaderError.downloadFailed(tail(of: result.stderr))
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw MediaDownloaderError.noOutputFile
        }
        return output
    }

    private static func hlsOutputName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let name = base.isEmpty || base == "/" ? "stream" : base
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(name)-\(formatter.string(from: Date())).mp4"
    }

    // MARK: - yt-dlp

    private static func downloadWithYtDlp(
        from url: URL,
        to folder: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> URL {
        guard let ytDlp = findYtDlp() else {
            throw MediaDownloaderError.ytDlpNotFound
        }

        var arguments = [
            "--no-playlist",
            "--newline",
            "--no-simulate",
            "--print", "after_move:filepath",
            "-f", "bv*+ba/b",
            "--merge-output-format", "mp4",
            "-o", folder.path + "/%(title)s.%(ext)s",
        ]
        if let ffmpeg = AudioExtractor.findFFmpeg() {
            arguments += ["--ffmpeg-location", ffmpeg.path]
        }
        arguments.append(url.absoluteString)

        // yt-dlp prints "[download]  42.3% of ..." progress lines and, thanks
        // to --print after_move:filepath, the final file path on its own line.
        let finalPath = LockedBox<String>()
        let result = try await runProcess(
            executable: ytDlp,
            arguments: arguments,
            onStdoutLine: { line in
                if let fraction = parseDownloadPercent(line) {
                    progress(fraction)
                } else if line.hasPrefix("/") {
                    finalPath.value = line
                }
            }
        )

        guard result.exitCode == 0 else {
            throw MediaDownloaderError.downloadFailed(tail(of: result.stderr))
        }
        guard let path = finalPath.value,
              FileManager.default.fileExists(atPath: path) else {
            throw MediaDownloaderError.noOutputFile
        }
        return URL(fileURLWithPath: path)
    }

    private static func parseDownloadPercent(_ line: String) -> Double? {
        guard line.hasPrefix("[download]"),
              let range = line.range(of: #"[0-9]+(\.[0-9]+)?%"#, options: .regularExpression),
              let percent = Double(line[range].dropLast())
        else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    private static func tail(of log: String) -> String {
        let lines = log.split(separator: "\n").map(String.init)
        let message = lines.suffix(2).joined(separator: " ")
        return message.isEmpty ? "unknown error" : message
    }

    // MARK: - Process helper

    private struct ProcessResult {
        let exitCode: Int32
        let stderr: String
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)?
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let lineSplitter = LineSplitter(onLine: onStdoutLine)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                lineSplitter.flush()
            } else {
                lineSplitter.append(data)
            }
        }

        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrTask = Task.detached { stderrHandle.readDataToEndOfFile() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()
        }

        let stderrData = await stderrTask.value
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try Task.checkCancellation()

        return ProcessResult(
            exitCode: process.terminationStatus,
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

/// Accumulates pipe data and emits complete lines; the readability handler
/// delivers arbitrary chunks on a background thread, so this type opts out
/// of the project's default MainActor isolation.
private nonisolated final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ data: Data) {
        guard onLine != nil else { return }
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        lock.unlock()
        for line in lines where !line.isEmpty {
            onLine?(line)
        }
    }

    func flush() {
        guard onLine != nil else { return }
        lock.lock()
        let remainder = String(data: buffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        lock.unlock()
        if let remainder, !remainder.isEmpty {
            onLine?(remainder)
        }
    }
}

/// Minimal thread-safe mutable box for values written from process callbacks.
private nonisolated final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}
