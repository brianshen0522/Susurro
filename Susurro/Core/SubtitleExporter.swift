import Foundation

enum SubtitleFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt
    case txt

    var id: String { rawValue }
    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .srt: return "SRT"
        case .vtt: return "WebVTT"
        case .txt: return String(localized: "export.plainText", defaultValue: "Plain Text")
        }
    }
}

enum SubtitleExporter {
    /// Writes subtitle content as UTF-8 **with BOM**. Plenty of players
    /// (PotPlayer, TVs, older VLC, Windows apps) guess the encoding of
    /// BOM-less .srt files from the system locale, turning CJK text into
    /// mojibake or tofu squares; the BOM pins the decode to UTF-8.
    static func write(_ content: String, to url: URL) throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(content.utf8))
        try data.write(to: url, options: .atomic)
    }

    static func export(_ transcript: FileTranscript, as format: SubtitleFormat) -> String {
        switch format {
        case .srt: return srt(transcript.segments)
        case .vtt: return vtt(transcript.segments)
        case .txt: return transcript.text + "\n"
        }
    }

    /// Pairs original and translated segments (same timings, index-aligned)
    /// into bilingual cues: translated line on top, original below.
    static func bilingual(original: [SubtitleSegment], translated: [SubtitleSegment]) -> [SubtitleSegment] {
        zip(original, translated).map { original, translated in
            SubtitleSegment(
                start: original.start,
                end: original.end,
                text: translated.text + "\n" + original.text
            )
        }
    }

    static func srt(_ segments: [SubtitleSegment]) -> String {
        segments.enumerated().map { index, segment in
            """
            \(index + 1)
            \(timestamp(segment.start, millisecondSeparator: ",")) --> \(timestamp(segment.end, millisecondSeparator: ","))
            \(segment.text)
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    static func vtt(_ segments: [SubtitleSegment]) -> String {
        "WEBVTT\n\n" + segments.map { segment in
            """
            \(timestamp(segment.start, millisecondSeparator: ".")) --> \(timestamp(segment.end, millisecondSeparator: "."))
            \(segment.text)
            """
        }
        .joined(separator: "\n\n") + "\n"
    }

    private static func timestamp(_ seconds: Double, millisecondSeparator: String) -> String {
        let totalMilliseconds = Int((seconds * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let secs = totalMilliseconds / 1000 % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d:%02d%@%03d", hours, minutes, secs, millisecondSeparator, milliseconds)
    }
}
