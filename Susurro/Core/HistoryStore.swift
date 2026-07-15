import Combine
import Foundation
import SwiftData

@MainActor
final class HistoryStore: ObservableObject {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func save(_ entry: TranscriptEntry) throws {
        modelContext.insert(entry)
        try modelContext.save()
    }

    func fetchAll(sortedByDateDescending: Bool = true) throws -> [TranscriptEntry] {
        let descriptor = FetchDescriptor<TranscriptEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: sortedByDateDescending ? .reverse : .forward)]
        )
        return try modelContext.fetch(descriptor)
    }

    func search(keyword: String) throws -> [TranscriptEntry] {
        let descriptor = FetchDescriptor<TranscriptEntry>(
            predicate: #Predicate { entry in
                entry.text.localizedStandardContains(keyword)
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    func delete(_ entry: TranscriptEntry) throws {
        modelContext.delete(entry)
        try modelContext.save()
    }

    func clearAll() throws {
        let all = try fetchAll()
        for entry in all {
            modelContext.delete(entry)
        }
        try modelContext.save()
    }
}
