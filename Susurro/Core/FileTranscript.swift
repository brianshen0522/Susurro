import Foundation
import SwiftData

/// One subtitle-sized chunk of a file transcription, with absolute times in
/// seconds from the start of the media.
struct SubtitleSegment: Codable, Hashable {
    var start: Double
    var end: Double
    var text: String
}

@Model
final class FileTranscript {
    var id: UUID
    var fileName: String
    var sourcePath: String
    var createdAt: Date
    var durationSeconds: Double
    var text: String
    /// JSON-encoded `[SubtitleSegment]` — SwiftData cannot store structs
    /// directly and the segments are only read back as a whole.
    var segmentsData: Data
    var modelName: String
    /// BCP-47 code of the spoken language Whisper detected (new transcripts
    /// only; used as the translation source hint).
    var language: String?
    /// JSON-encoded `[String: [SubtitleSegment]]` keyed by BCP-47 target
    /// code (e.g. "zh-Hant"); each value shares the original timings.
    var translationsData: Data?

    init(
        fileName: String,
        sourcePath: String,
        durationSeconds: Double,
        text: String,
        segments: [SubtitleSegment],
        modelName: String,
        language: String? = nil
    ) {
        self.id = UUID()
        self.fileName = fileName
        self.sourcePath = sourcePath
        self.createdAt = Date()
        self.durationSeconds = durationSeconds
        self.text = text
        self.segmentsData = (try? JSONEncoder().encode(segments)) ?? Data()
        self.modelName = modelName
        self.language = language
    }

    var segments: [SubtitleSegment] {
        (try? JSONDecoder().decode([SubtitleSegment].self, from: segmentsData)) ?? []
    }

    var translations: [String: [SubtitleSegment]] {
        guard let translationsData,
              let decoded = try? JSONDecoder().decode([String: [SubtitleSegment]].self, from: translationsData)
        else { return [:] }
        return decoded
    }

    func setTranslation(segments: [SubtitleSegment], languageCode: String) {
        var all = translations
        all[languageCode] = segments
        translationsData = try? JSONEncoder().encode(all)
    }
}
