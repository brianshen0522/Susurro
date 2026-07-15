import AppKit
import SwiftData
import SwiftUI
import Translation
import UniformTypeIdentifiers

/// Curated translation targets offered in the options sheet and the
/// per-transcript Translate menu.
enum TranslationTarget: String, CaseIterable, Identifiable {
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"
    case korean = "ko"
    case spanish = "es"
    case french = "fr"
    case german = "de"

    var id: String { rawValue }
    var language: Locale.Language { Locale.Language(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .traditionalChinese: return "繁體中文"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .spanish: return "Español"
        case .french: return "Français"
        case .german: return "Deutsch"
        }
    }

    static func displayName(for code: String) -> String {
        TranslationTarget(rawValue: code)?.displayName
            ?? Locale.current.localizedString(forIdentifier: code)
            ?? code
    }
}

struct FileTranscriptionView: View {
    @EnvironmentObject var fileService: FileTranscriptionService
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var navigation: NavigationModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FileTranscript.createdAt, order: .reverse) private var transcripts: [FileTranscript]

    @State private var isDropTargeted = false
    @State private var urlString = ""
    @State private var newJobSource: NewJobSource?

    /// The translation the `.translationTask` closure should perform next.
    private enum ActiveTranslation: Equatable {
        case manual(transcriptID: UUID, targetCode: String)
        case auto(requestID: UUID, transcriptID: UUID, targetCode: String)

        var transcriptID: UUID {
            switch self {
            case .manual(let id, _), .auto(_, let id, _): return id
            }
        }

        var targetCode: String {
            switch self {
            case .manual(_, let code), .auto(_, _, let code): return code
            }
        }
    }

    @State private var activeTranslation: ActiveTranslation?
    @State private var autoTargetsRemaining: [String] = []
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var translationError: String?
    /// Fraction of the current translation (manual: shown on the transcript
    /// row; auto: folded into the job's overall progress).
    @State private var translationProgress: Double?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if modelManager.currentlyLoadedModel == nil {
                    noModelBanner
                }
                dropZone
                urlSection
                if !fileService.jobs.isEmpty {
                    jobsSection
                }
                resultsSection
            }
            .padding()
        }
        .navigationTitle(String(localized: "page.files", defaultValue: "Files"))
        .sheet(item: $newJobSource) { source in
            TranscriptionOptionsSheet(source: source) { options, exportFolder in
                switch source {
                case .localFiles(let urls):
                    fileService.enqueue(urls: urls, options: options)
                case .remote(let url):
                    guard let exportFolder else { return }
                    fileService.enqueueRemote(url: url, exportFolder: exportFolder, options: options)
                    urlString = ""
                }
            }
        }
        .translationTask(translationConfig) { session in
            await runTranslation(session)
        }
        .onAppear { processNextAutoRequestIfIdle() }
        .onChange(of: fileService.pendingAutoTranslations) { _, _ in
            processNextAutoRequestIfIdle()
        }
        .alert(
            String(localized: "files.translationFailed", defaultValue: "Translation Failed"),
            isPresented: Binding(
                get: { translationError != nil },
                set: { if !$0 { translationError = nil } }
            )
        ) {
            Button(String(localized: "ok", defaultValue: "OK"), role: .cancel) {}
        } message: {
            Text(translationError ?? "")
        }
    }

    // MARK: - Translation driving

    private func startManualTranslation(_ transcript: FileTranscript, to target: TranslationTarget) {
        guard activeTranslation == nil else { return }
        activeTranslation = .manual(transcriptID: transcript.id, targetCode: target.rawValue)
        configureSession(transcript: transcript, targetCode: target.rawValue)
    }

    private func processNextAutoRequestIfIdle() {
        guard activeTranslation == nil,
              let request = fileService.pendingAutoTranslations.first else { return }
        autoTargetsRemaining = request.targets
        startNextAutoTarget(for: request)
    }

    private func startNextAutoTarget(for request: FileTranscriptionService.AutoTranslationRequest) {
        // The request may have been cancelled from the job row.
        guard fileService.pendingAutoTranslations.contains(where: { $0.id == request.id }) else {
            activeTranslation = nil
            processNextAutoRequestIfIdle()
            return
        }
        guard let transcript = transcripts.first(where: { $0.id == request.transcriptID }) else {
            fileService.completeAutoTranslation(requestID: request.id, errorMessage: nil)
            activeTranslation = nil
            return
        }
        guard let code = autoTargetsRemaining.first else {
            finishAutoRequest(request, transcript: transcript)
            return
        }

        fileService.setTranslatingPhase(
            jobID: request.id,
            languageName: TranslationTarget.displayName(for: code),
            progress: overallAutoProgress(request: request, currentFraction: 0)
        )
        activeTranslation = .auto(requestID: request.id, transcriptID: request.transcriptID, targetCode: code)
        configureSession(transcript: transcript, targetCode: code)
    }

    /// Overall fraction across every requested language, so a three-language
    /// job's bar runs 0→1 once instead of three times.
    private func overallAutoProgress(
        request: FileTranscriptionService.AutoTranslationRequest,
        currentFraction: Double
    ) -> Double {
        let total = max(request.targets.count, 1)
        let completed = total - autoTargetsRemaining.count
        return (Double(completed) + currentFraction) / Double(total)
    }

    private func configureSession(transcript: FileTranscript, targetCode: String) {
        let source = transcript.language.map { Locale.Language(identifier: $0) }
        translationConfig = TranslationSession.Configuration(
            source: source,
            target: Locale.Language(identifier: targetCode)
        )
    }

    private func runTranslation(_ session: TranslationSession) async {
        guard let active = activeTranslation,
              let transcript = transcripts.first(where: { $0.id == active.transcriptID }) else {
            activeTranslation = nil
            return
        }

        let segments = transcript.segments
        translationProgress = nil
        defer { translationProgress = nil }
        do {
            guard !segments.isEmpty else {
                throw TranslationSkipError()
            }
            // Downloads the language pair (with a system prompt) if needed.
            try await session.prepareTranslation()

            let requests = segments.enumerated().map { index, segment in
                TranslationSession.Request(sourceText: segment.text, clientIdentifier: "\(index)")
            }

            // Stream responses so the progress bar moves as segments finish.
            var translated = segments
            var completedCount = 0
            for try await response in session.translate(batch: requests) {
                if let identifier = response.clientIdentifier,
                   let index = Int(identifier),
                   translated.indices.contains(index) {
                    translated[index].text = response.targetText
                }
                completedCount += 1
                reportTranslationProgress(
                    Double(completedCount) / Double(requests.count),
                    for: active
                )
            }

            transcript.setTranslation(segments: translated, languageCode: active.targetCode)
            try? modelContext.save()
            handleTranslationSuccess(active, transcript: transcript)
        } catch is CancellationError {
            activeTranslation = nil
        } catch {
            handleTranslationFailure(active, message: (error is TranslationSkipError) ? nil : error.localizedDescription)
        }
    }

    private func reportTranslationProgress(_ fraction: Double, for active: ActiveTranslation) {
        switch active {
        case .manual:
            translationProgress = fraction
        case .auto(let requestID, _, let code):
            guard let request = fileService.pendingAutoTranslations.first(where: { $0.id == requestID }) else { return }
            fileService.setTranslatingPhase(
                jobID: requestID,
                languageName: TranslationTarget.displayName(for: code),
                progress: overallAutoProgress(request: request, currentFraction: fraction)
            )
        }
    }

    private struct TranslationSkipError: Error {}

    private func handleTranslationSuccess(_ active: ActiveTranslation, transcript: FileTranscript) {
        switch active {
        case .manual:
            activeTranslation = nil
        case .auto(let requestID, _, let code):
            autoTargetsRemaining.removeAll { $0 == code }
            guard let request = fileService.pendingAutoTranslations.first(where: { $0.id == requestID }) else {
                activeTranslation = nil
                processNextAutoRequestIfIdle()
                return
            }
            startNextAutoTarget(for: request)
        }
    }

    private func handleTranslationFailure(_ active: ActiveTranslation, message: String?) {
        switch active {
        case .manual:
            translationError = message
        case .auto(let requestID, _, _):
            fileService.completeAutoTranslation(
                requestID: requestID,
                errorMessage: message.map {
                    String(localized: "files.autoTranslateFailed", defaultValue: "Transcript saved, but translation failed: \($0)")
                }
            )
        }
        activeTranslation = nil
        processNextAutoRequestIfIdle()
    }

    /// All targets translated: write the requested subtitle files and close
    /// out the job.
    private func finishAutoRequest(
        _ request: FileTranscriptionService.AutoTranslationRequest,
        transcript: FileTranscript
    ) {
        var writeError: String?
        do {
            for code in request.targets {
                guard let translated = transcript.translations[code] else { continue }
                if request.outputs.contains(.translated) {
                    let url = request.subtitleFolder.appendingPathComponent("\(request.baseName).\(code).srt")
                    try SubtitleExporter.write(SubtitleExporter.srt(translated), to: url)
                }
                if request.outputs.contains(.bilingual) {
                    let combined = SubtitleExporter.bilingual(original: transcript.segments, translated: translated)
                    let url = request.subtitleFolder.appendingPathComponent("\(request.baseName).\(code).bilingual.srt")
                    try SubtitleExporter.write(SubtitleExporter.srt(combined), to: url)
                }
            }
        } catch {
            writeError = String(
                localized: "files.subtitleWriteFailed",
                defaultValue: "Translations saved, but writing subtitle files failed: \(error.localizedDescription)"
            )
        }
        fileService.completeAutoTranslation(requestID: request.id, errorMessage: writeError)
        activeTranslation = nil
        processNextAutoRequestIfIdle()
    }

    // MARK: - URL input

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField(
                    String(localized: "files.urlPlaceholder", defaultValue: "Paste a YouTube or M3U8 URL"),
                    text: $urlString
                )
                .textFieldStyle(.roundedBorder)
                .onSubmit { submitURL() }

                Button(String(localized: "files.downloadAndTranscribe", defaultValue: "Download & Transcribe")) {
                    submitURL()
                }
                .disabled(enteredURL == nil)
            }
            Text(String(
                localized: "files.urlHint",
                defaultValue: "You'll pick the export folder, translation languages, and subtitle files next."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var enteredURL: URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host() != nil
        else { return nil }
        return url
    }

    private func submitURL() {
        guard let url = enteredURL else { return }
        newJobSource = .remote(url)
    }

    // MARK: - Model banner

    private var noModelBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(
                localized: "files.noModelBanner",
                defaultValue: "No model loaded — file transcription needs a local model."
            ))
            .font(.callout)
            Spacer()
            Button(String(localized: "files.openSettings", defaultValue: "Open Settings")) {
                navigation.selectedPage = .settings
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 28))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text(String(
                localized: "files.dropHint",
                defaultValue: "Drop audio or video files here"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            Button(String(localized: "files.chooseFiles", defaultValue: "Choose Files…")) {
                chooseFiles()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
        )
        .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let loadable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loadable.isEmpty else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in loadable {
                if let url = try? await loadURL(from: provider), url.isFileURL {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                newJobSource = .localFiles(urls)
            }
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: url)
                }
            }
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = String(
            localized: "files.openPanelMessage",
            defaultValue: "Choose audio or video files to transcribe"
        )
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                guard !urls.isEmpty else { return }
                newJobSource = .localFiles(urls)
            }
        }
    }

    // MARK: - Active jobs

    private var jobsSection: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(fileService.jobs) { job in
                    JobRowView(
                        job: job,
                        onCancel: { fileService.cancel(jobID: job.id) },
                        onDismiss: { fileService.dismiss(jobID: job.id) }
                    )
                    if job.id != fileService.jobs.last?.id {
                        Divider()
                    }
                }
            }
        } label: {
            Label(String(localized: "files.queue", defaultValue: "In Progress"), systemImage: "arrow.triangle.2.circlepath")
        }
    }

    // MARK: - Results

    private var resultsSection: some View {
        GroupBox {
            if transcripts.isEmpty {
                Text(String(
                    localized: "files.empty",
                    defaultValue: "Transcribed files will appear here."
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(transcripts) { transcript in
                        FileTranscriptRowView(
                            transcript: transcript,
                            isTranslating: activeTranslation?.transcriptID == transcript.id,
                            translationProgress: activeTranslation?.transcriptID == transcript.id
                                ? translationProgress : nil,
                            onTranslate: { target in
                                startManualTranslation(transcript, to: target)
                            },
                            onDelete: {
                                modelContext.delete(transcript)
                            }
                        )
                        if transcript.id != transcripts.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "files.results", defaultValue: "Transcripts"), systemImage: "doc.text")
        }
    }
}

// MARK: - Job row

private struct JobRowView: View {
    let job: FileTranscriptionService.Job
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                switch job.phase {
                case .waiting, .downloading, .extracting, .transcribing, .translating:
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "cancel", defaultValue: "Cancel"))
                case .failed:
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "dismiss", defaultValue: "Dismiss"))
                }
            }

            switch job.phase {
            case .waiting:
                Text(String(localized: "files.waiting", defaultValue: "Waiting…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .downloading(let fraction):
                if let fraction {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                        Text(String(
                            localized: "files.downloading",
                            defaultValue: "Downloading… \(Int(fraction * 100))%"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(String(localized: "files.downloadingIndeterminate", defaultValue: "Downloading…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .extracting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text(String(localized: "files.extracting", defaultValue: "Extracting audio…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .transcribing(let fraction):
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                    Text(String(
                        localized: "files.transcribing",
                        defaultValue: "Transcribing… \(Int(fraction * 100))%"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            case .translating(let languageName, let progress):
                let label = languageName.map {
                    String(localized: "files.translatingLanguage", defaultValue: "Translating (\($0))…")
                } ?? String(localized: "files.translating", defaultValue: "Translating…")
                if let progress {
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                        Text("\(label) \(Int(progress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
    }
}

// MARK: - Transcript row

private struct FileTranscriptRowView: View {
    let transcript: FileTranscript
    let isTranslating: Bool
    let translationProgress: Double?
    let onTranslate: (TranslationTarget) -> Void
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(transcript.fileName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(transcript.createdAt, style: .date)
                        Text(formattedDuration)
                        Text(transcript.modelName)
                        ForEach(translationCodes, id: \.self) { code in
                            Text("→ \(TranslationTarget.displayName(for: code))")
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if isTranslating {
                    HStack(spacing: 6) {
                        if let translationProgress {
                            ProgressView(value: translationProgress)
                                .progressViewStyle(.linear)
                                .frame(width: 70)
                            Text("\(Int(translationProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text(String(localized: "files.translating", defaultValue: "Translating…"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    translateMenu
                }
                exportMenu
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(String(localized: "delete", defaultValue: "Delete"))
            }

            Text(transcript.text)
                .font(.callout)
                .lineLimit(isExpanded ? nil : 2)
                .textSelection(.enabled)

            if transcript.text.count > 120 {
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
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .confirmationDialog(
            String(localized: "files.deleteConfirm", defaultValue: "Delete this transcript?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                onDelete()
            }
        }
    }

    private var translationCodes: [String] {
        transcript.translations.keys.sorted()
    }

    private var translateMenu: some View {
        Menu {
            ForEach(TranslationTarget.allCases) { target in
                Button(target.displayName) {
                    onTranslate(target)
                }
            }
        } label: {
            Label(String(localized: "files.translate", defaultValue: "Translate"), systemImage: "character.bubble")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var exportMenu: some View {
        Menu {
            ForEach(SubtitleFormat.allCases) { format in
                Button(String(localized: "files.exportAs", defaultValue: "Export \(format.displayName)…")) {
                    export(content: SubtitleExporter.export(transcript, as: format), fileExtension: format.fileExtension)
                }
            }
            ForEach(translationCodes, id: \.self) { code in
                if let translated = transcript.translations[code] {
                    Section(TranslationTarget.displayName(for: code)) {
                        Button(String(localized: "files.exportTranslatedSRT", defaultValue: "Export Translated SRT…")) {
                            export(
                                content: SubtitleExporter.srt(translated),
                                fileExtension: "srt",
                                suffix: code
                            )
                        }
                        Button(String(localized: "files.exportBilingualSRT", defaultValue: "Export Bilingual SRT…")) {
                            let combined = SubtitleExporter.bilingual(original: transcript.segments, translated: translated)
                            export(
                                content: SubtitleExporter.srt(combined),
                                fileExtension: "srt",
                                suffix: code + ".bilingual"
                            )
                        }
                    }
                }
            }
            Divider()
            Button(String(localized: "history.copy", defaultValue: "Copy Text")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(transcript.text, forType: .string)
            }
        } label: {
            Label(String(localized: "files.export", defaultValue: "Export"), systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func export(content: String, fileExtension: String, suffix: String? = nil) {
        let panel = NSSavePanel()
        let baseName = (transcript.fileName as NSString).deletingPathExtension
        let name = suffix.map { "\(baseName).\($0)" } ?? baseName
        panel.nameFieldStringValue = "\(name).\(fileExtension)"
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? SubtitleExporter.write(content, to: url)
        }
    }

    private var formattedDuration: String {
        let total = Int(transcript.durationSeconds.rounded())
        let hours = total / 3600
        let minutes = total / 60 % 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
