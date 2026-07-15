import SwiftData
import SwiftUI

struct HistoryListView: View {
    @EnvironmentObject var appController: AppController
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \TranscriptEntry.timestamp, order: .reverse) private var entries: [TranscriptEntry]

    @State private var searchText = ""
    @State private var selectedEntry: TranscriptEntry?
    @State private var showClearConfirm = false

    var filteredEntries: [TranscriptEntry] {
        if searchText.isEmpty { return entries }
        return entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()

            if filteredEntries.isEmpty {
                emptyState
            } else {
                List(filteredEntries, selection: $selectedEntry) { entry in
                    HistoryEntryRow(entry: entry)
                        .tag(entry)
                        .contextMenu {
                            Button(String(localized: "history.copy", defaultValue: "Copy Text")) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.text, forType: .string)
                            }
                            Divider()
                            Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                                modelContext.delete(entry)
                            }
                        }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(String(localized: "page.transcript", defaultValue: "Transcript"))
        .toolbar {
            ToolbarItem {
                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .confirmationDialog(
            String(localized: "history.clearAll", defaultValue: "Clear all history?"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "history.clearAll", defaultValue: "Clear All"), role: .destructive) {
                for entry in entries {
                    modelContext.delete(entry)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(String(localized: "history.search", defaultValue: "Search transcriptions…"), text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            String(localized: "history.empty.title", defaultValue: "No Transcriptions"),
            systemImage: "waveform",
            description: Text(String(localized: "history.empty.description", defaultValue: "Transcriptions will appear here after you use dictation."))
        )
    }
}

struct HistoryEntryRow: View {
    let entry: TranscriptEntry
    @State private var isExpanded = false
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.timestamp, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.sourceDescription)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(Capsule())

                Text(String(format: "%.1fs", entry.durationSeconds))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Button {
                    copyText()
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(justCopied ? .green : .secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .help(String(localized: "history.copy", defaultValue: "Copy Text"))
            }

            Text(entry.text)
                .font(.body)
                .lineLimit(isExpanded ? nil : 2)
                .animation(.easeInOut(duration: 0.2), value: isExpanded)

            if entry.text.count > 100 {
                Button {
                    isExpanded.toggle()
                } label: {
                    Text(isExpanded
                         ? String(localized: "history.showLess", defaultValue: "Show less")
                         : String(localized: "history.showMore", defaultValue: "Show more"))
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        justCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            justCopied = false
        }
    }
}
