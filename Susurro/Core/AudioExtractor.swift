import AVFoundation
import Foundation

enum AudioExtractorError: LocalizedError {
    case noAudioTrack
    case notReadable
    case readFailed(String)
    case ffmpegNotFound
    case ffmpegFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return String(localized: "extract.noAudioTrack", defaultValue: "This file contains no audio track.")
        case .notReadable:
            return String(localized: "extract.notReadable", defaultValue: "This file could not be read.")
        case .readFailed(let msg):
            return String(localized: "extract.readFailed", defaultValue: "Failed to decode audio: \(msg)")
        case .ffmpegNotFound:
            return String(
                localized: "extract.ffmpegNotFound",
                defaultValue: "This format needs ffmpeg, which was not found. Install it with \"brew install ffmpeg\" and try again."
            )
        case .ffmpegFailed(let msg):
            return String(localized: "extract.ffmpegFailed", defaultValue: "ffmpeg failed to convert this file: \(msg)")
        }
    }
}

/// Decodes any audio or video file into the 16 kHz mono Float32 WAV that
/// WhisperKit expects. Containers macOS can read natively (mp3/m4a/wav/flac,
/// mp4/mov, …) go through AVFoundation; everything else (mkv/webm/ogg/opus,
/// …) falls back to an ffmpeg subprocess.
enum AudioExtractor {
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    static func extract16kHzMonoWAV(from source: URL) async throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("susurro-extract-\(UUID().uuidString).wav")

        do {
            try await extractWithAVFoundation(from: source, to: output)
            return output
        } catch let error as AudioExtractorError {
            switch error {
            case .notReadable:
                try await extractWithFFmpeg(from: source, to: output)
                return output
            default:
                throw error
            }
        }
    }

    // MARK: - AVFoundation path

    private static func extractWithAVFoundation(from source: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard (try? await asset.load(.isReadable)) == true else {
            throw AudioExtractorError.notReadable
        }
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioExtractorError.notReadable
        }
        guard !tracks.isEmpty else { throw AudioExtractorError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioExtractorError.notReadable
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        guard reader.canAdd(readerOutput) else { throw AudioExtractorError.notReadable }
        reader.add(readerOutput)
        guard reader.startReading() else {
            throw AudioExtractorError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        let file = try AVAudioFile(forWriting: output, settings: whisperFormat.settings)
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let frames = AVAudioFrameCount(length / MemoryLayout<Float32>.size)
            guard frames > 0,
                  let pcm = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: frames) else { continue }
            pcm.frameLength = frames
            let status = CMBlockBufferCopyDataBytes(
                block,
                atOffset: 0,
                dataLength: length,
                destination: pcm.floatChannelData![0]
            )
            guard status == kCMBlockBufferNoErr else {
                throw AudioExtractorError.readFailed("buffer copy failed (\(status))")
            }
            try file.write(from: pcm)
        }

        switch reader.status {
        case .completed:
            return
        case .cancelled:
            throw CancellationError()
        default:
            throw AudioExtractorError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
    }

    // MARK: - ffmpeg fallback

    static func findFFmpeg() -> URL? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg",
        ]
        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            candidates += envPath.split(separator: ":").map { "\($0)/ffmpeg" }
        }
        return candidates
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func extractWithFFmpeg(from source: URL, to output: URL) async throws {
        guard let ffmpeg = findFFmpeg() else { throw AudioExtractorError.ffmpegNotFound }

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", source.path,
            "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_f32le", "-f", "wav",
            output.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        // Drain stderr while the process runs — ffmpeg logs enough that an
        // unread pipe fills up and deadlocks long conversions.
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
        try Task.checkCancellation()

        guard process.terminationStatus == 0 else {
            let log = String(data: stderrData, encoding: .utf8) ?? ""
            let tail = log.split(separator: "\n").suffix(2).joined(separator: " ")
            throw AudioExtractorError.ffmpegFailed(tail.isEmpty ? "exit code \(process.terminationStatus)" : tail)
        }
    }
}
