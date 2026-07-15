import Foundation
import SwiftData

@Model
final class TranscriptEntry {
    var id: UUID
    var text: String
    var timestamp: Date
    var durationSeconds: Double
    var sourceDescription: String

    init(text: String, timestamp: Date, durationSeconds: Double, sourceDescription: String) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.durationSeconds = durationSeconds
        self.sourceDescription = sourceDescription
    }
}
