import AppKit
import SwiftUI

/// What the user is about to transcribe; shown in the options sheet.
enum NewJobSource: Identifiable {
    case localFiles([URL])
    case remote(URL)

    var id: String {
        switch self {
        case .localFiles(let urls): return "files:" + urls.map(\.path).joined(separator: "|")
        case .remote(let url): return "url:" + url.absoluteString
        }
    }
}

/// Pre-flight options sheet shown before any file/URL transcription starts.
struct TranscriptionOptionsSheet: View {
    let source: NewJobSource
    let onStart: (TranscriptionJobOptions, _ exportFolder: URL?) -> Void

    @Environment(\.dismiss) private var dismiss

    // Remembered across jobs.
    @AppStorage("fileJob.translationTargets") private var storedTargets = ""
    @AppStorage("fileJob.outputs") private var storedOutputs = SubtitleOutput.original.rawValue

    @State private var selectedTargets: Set<String> = []
    @State private var selectedOutputs: Set<SubtitleOutput> = [.original]
    @State private var exportFolder: URL?

    private var isRemote: Bool {
        if case .remote = source { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "sheet.title", defaultValue: "New Transcription"))
                .font(.headline)

            sourceSummary

            if isRemote {
                folderRow
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    languageGrid
                    Text(String(
                        localized: "sheet.translateHint",
                        defaultValue: "Translation runs on-device after transcription. Leave everything unchecked to keep the original language only."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(4)
            } label: {
                Label(String(localized: "sheet.translateTo", defaultValue: "Translate To"), systemImage: "character.bubble")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SubtitleOutput.allCases) { output in
                        Toggle(output.displayName, isOn: outputBinding(output))
                            .disabled(output != .original && selectedTargets.isEmpty)
                    }
                    Text(subtitleFilesHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            } label: {
                Label(String(localized: "sheet.subtitleFiles", defaultValue: "Subtitle Files"), systemImage: "doc.badge.plus")
            }

            HStack {
                Spacer()
                Button(String(localized: "cancel", defaultValue: "Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(String(localized: "sheet.start", defaultValue: "Start")) {
                    persistChoices()
                    let options = TranscriptionJobOptions(
                        translationTargets: TranslationTarget.allCases
                            .map(\.rawValue)
                            .filter { selectedTargets.contains($0) },
                        outputs: effectiveOutputs
                    )
                    dismiss()
                    onStart(options, exportFolder)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isRemote && exportFolder == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear(perform: restoreChoices)
    }

    // MARK: - Rows

    private var sourceSummary: some View {
        Group {
            switch source {
            case .localFiles(let urls):
                if urls.count == 1 {
                    Label(urls[0].lastPathComponent, systemImage: "doc")
                } else {
                    Label(
                        String(localized: "sheet.fileCount", defaultValue: "\(urls.count) files"),
                        systemImage: "doc.on.doc"
                    )
                }
            case .remote(let url):
                Label(url.absoluteString, systemImage: "link")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundStyle(.secondary)
    }

    private var folderRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(exportFolder?.path(percentEncoded: false)
                 ?? String(localized: "sheet.noFolder", defaultValue: "Choose where to save the video…"))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(exportFolder == nil ? .secondary : .primary)
            Spacer()
            Button(String(localized: "sheet.chooseFolder", defaultValue: "Choose…")) {
                chooseFolder()
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private var languageGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 6) {
            ForEach(TranslationTarget.allCases) { target in
                Toggle(target.displayName, isOn: targetBinding(target))
            }
        }
    }

    private var subtitleFilesHint: String {
        switch source {
        case .localFiles:
            return String(
                localized: "sheet.subtitleHint.local",
                defaultValue: "Files are written next to each media file, named like \"video.zh-Hant.srt\". Uncheck everything to keep results in the app only."
            )
        case .remote:
            return String(
                localized: "sheet.subtitleHint.remote",
                defaultValue: "Files are written next to the downloaded video, named like \"video.zh-Hant.srt\"."
            )
        }
    }

    // MARK: - Bindings & persistence

    private func targetBinding(_ target: TranslationTarget) -> Binding<Bool> {
        Binding(
            get: { selectedTargets.contains(target.rawValue) },
            set: { isOn in
                if isOn {
                    selectedTargets.insert(target.rawValue)
                } else {
                    selectedTargets.remove(target.rawValue)
                }
            }
        )
    }

    private func outputBinding(_ output: SubtitleOutput) -> Binding<Bool> {
        Binding(
            get: { selectedOutputs.contains(output) },
            set: { isOn in
                if isOn {
                    selectedOutputs.insert(output)
                } else {
                    selectedOutputs.remove(output)
                }
            }
        )
    }

    /// Translated/bilingual outputs are meaningless without a target language.
    private var effectiveOutputs: Set<SubtitleOutput> {
        selectedTargets.isEmpty ? selectedOutputs.intersection([.original]) : selectedOutputs
    }

    private func restoreChoices() {
        selectedTargets = Set(storedTargets.split(separator: ",").map(String.init))
        selectedOutputs = Set(storedOutputs.split(separator: ",").compactMap { SubtitleOutput(rawValue: String($0)) })
        if selectedOutputs.isEmpty && storedOutputs.isEmpty {
            selectedOutputs = [.original]
        }
    }

    private func persistChoices() {
        storedTargets = selectedTargets.sorted().joined(separator: ",")
        storedOutputs = selectedOutputs.map(\.rawValue).sorted().joined(separator: ",")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "files.saveHere", defaultValue: "Save Here")
        panel.message = String(
            localized: "files.chooseExportFolder",
            defaultValue: "Choose a folder for the downloaded video and its subtitles"
        )
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            exportFolder = folder
        }
    }
}
