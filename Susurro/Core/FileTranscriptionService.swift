import AVFoundation
import Combine
import Foundation
import SwiftData
import SwiftUI
import WhisperKit

/// Thread-safe cancellation flag readable from WhisperKit's callback
/// threads; `nonisolated` opts it out of the project's default MainActor
/// isolation.
private nonisolated final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Which subtitle files get written next to the media.
enum SubtitleOutput: String, CaseIterable, Identifiable, Codable {
    case original
    case translated
    case bilingual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .original:
            return String(localized: "output.original", defaultValue: "Original SRT")
        case .translated:
            return String(localized: "output.translated", defaultValue: "Translated SRT")
        case .bilingual:
            return String(localized: "output.bilingual", defaultValue: "Bilingual SRT")
        }
    }
}

/// Per-job choices collected in the options sheet before a job starts.
struct TranscriptionJobOptions: Equatable {
    /// BCP-47 codes to auto-translate into after transcription.
    var translationTargets: [String] = []
    /// Subtitle files to write next to the media; empty = library only.
    var outputs: Set<SubtitleOutput> = [.original]
}

@MainActor
final class FileTranscriptionService: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case downloading(Double?) // fraction 0...1, nil when indeterminate
        case extracting
        case transcribing(Double) // fraction 0...1
        // Display name of the language in progress + overall fraction
        // across all requested languages (nil while preparing).
        case translating(language: String?, progress: Double?)
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        enum Source: Equatable {
            case localFile(URL)
            /// Remote media; the video and its subtitles land in `exportFolder`.
            case remote(URL, exportFolder: URL)
        }

        let id: UUID
        let source: Source
        let options: TranscriptionJobOptions
        var phase: Phase
        /// Local file name once known; the URL string until then.
        var displayName: String
    }

    /// Auto-translation the UI must perform once a job's transcription is
    /// done — Apple's TranslationSession only exists inside a SwiftUI
    /// `.translationTask`, so the service cannot run it itself.
    struct AutoTranslationRequest: Identifiable, Equatable {
        let id: UUID // same as the owning job's ID
        let transcriptID: UUID
        let targets: [String]
        let outputs: Set<SubtitleOutput>
        let subtitleFolder: URL
        let baseName: String
    }

    @Published private(set) var jobs: [Job] = []
    @Published private(set) var pendingAutoTranslations: [AutoTranslationRequest] = []
    /// True only while WhisperKit itself is transcribing a file — dictation
    /// must not run concurrently against the same model instance.
    @Published private(set) var isEngineBusy = false

    private let modelManager: ModelManager
    private let modelContext: ModelContext
    private let settingsStore: SettingsStore
    weak var appController: AppController?

    private var processingTask: Task<Void, Never>?
    private var currentJobTask: Task<Void, Never>?
    private var currentCancellationFlag: CancellationFlag?
    private var activityToken: NSObjectProtocol?

    init(modelManager: ModelManager, modelContext: ModelContext, settingsStore: SettingsStore) {
        self.modelManager = modelManager
        self.modelContext = modelContext
        self.settingsStore = settingsStore
    }

    func enqueue(urls: [URL], options: TranscriptionJobOptions) {
        let newJobs = urls.map {
            Job(id: UUID(), source: .localFile($0), options: options, phase: .waiting, displayName: $0.lastPathComponent)
        }
        guard !newJobs.isEmpty else { return }
        jobs.append(contentsOf: newJobs)
        startProcessingIfNeeded()
    }

    func enqueueRemote(url: URL, exportFolder: URL, options: TranscriptionJobOptions) {
        jobs.append(Job(
            id: UUID(),
            source: .remote(url, exportFolder: exportFolder),
            options: options,
            phase: .waiting,
            displayName: url.absoluteString
        ))
        startProcessingIfNeeded()
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].phase {
        case .waiting, .failed:
            jobs.remove(at: index)
        case .translating:
            pendingAutoTranslations.removeAll { $0.id == jobID }
            jobs.remove(at: index)
        case .downloading, .extracting, .transcribing:
            currentCancellationFlag?.set()
            currentJobTask?.cancel()
        }
    }

    /// Called by the UI as an auto-translation advances, to keep the job
    /// row's status text and progress bar current.
    func setTranslatingPhase(jobID: UUID, languageName: String?, progress: Double?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              case .translating = jobs[index].phase else { return }
        jobs[index].phase = .translating(language: languageName, progress: progress)
    }

    /// Called by the UI when an auto-translation request finishes (or dies).
    func completeAutoTranslation(requestID: UUID, errorMessage: String?) {
        pendingAutoTranslations.removeAll { $0.id == requestID }
        if let errorMessage {
            fail(requestID, message: errorMessage)
        } else {
            jobs.removeAll { $0.id == requestID }
        }
    }

    func dismiss(jobID: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == jobID }),
           case .failed = jobs[index].phase {
            jobs.remove(at: index)
        }
    }

    // MARK: - Queue

    private func startProcessingIfNeeded() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.processQueue()
            self?.processingTask = nil
        }
    }

    private func processQueue() async {
        beginActivity()
        defer { endActivity() }

        while let index = jobs.firstIndex(where: { $0.phase == .waiting }) {
            let job = jobs[index]
            let flag = CancellationFlag()
            currentCancellationFlag = flag
            let task = Task { await self.run(job, cancellationFlag: flag) }
            currentJobTask = task
            await task.value
            currentJobTask = nil
            currentCancellationFlag = nil
        }
    }

    private func run(_ job: Job, cancellationFlag: CancellationFlag) async {
        guard modelManager.currentlyLoadedModel != nil else {
            fail(job.id, message: String(
                localized: "files.noModel",
                defaultValue: "No model loaded. Load a model in Settings first."
            ))
            return
        }

        let jobID = job.id

        // Resolve the source down to a local media file, downloading first
        // for remote jobs.
        let mediaURL: URL
        switch job.source {
        case .localFile(let url):
            mediaURL = url
        case .remote(let remoteURL, let exportFolder):
            updatePhase(jobID, .downloading(nil))
            do {
                mediaURL = try await MediaDownloader.download(from: remoteURL, to: exportFolder) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        self?.updateDownloadProgress(jobID, fraction)
                    }
                }
            } catch is CancellationError {
                jobs.removeAll { $0.id == jobID }
                return
            } catch {
                if cancellationFlag.isSet {
                    jobs.removeAll { $0.id == jobID }
                } else {
                    fail(jobID, message: error.localizedDescription)
                }
                return
            }
            if let index = jobs.firstIndex(where: { $0.id == jobID }) {
                jobs[index].displayName = mediaURL.lastPathComponent
            }
        }

        updatePhase(jobID, .extracting)

        let wavURL: URL
        do {
            wavURL = try await AudioExtractor.extract16kHzMonoWAV(from: mediaURL)
        } catch is CancellationError {
            jobs.removeAll { $0.id == jobID }
            return
        } catch {
            if cancellationFlag.isSet {
                jobs.removeAll { $0.id == jobID }
            } else {
                fail(jobID, message: error.localizedDescription)
            }
            return
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let duration: Double
        do {
            let audioFile = try AVAudioFile(forReading: wavURL)
            duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        } catch {
            fail(job.id, message: error.localizedDescription)
            return
        }

        // Give an in-flight dictation priority; file jobs can wait.
        while let controller = appController, controller.dictationState != .idle {
            if cancellationFlag.isSet {
                jobs.removeAll { $0.id == jobID }
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        guard let kit = modelManager.getWhisperKit() else {
            fail(jobID, message: String(
                localized: "files.noModel",
                defaultValue: "No model loaded. Load a model in Settings first."
            ))
            return
        }

        updatePhase(jobID, .transcribing(0))
        isEngineBusy = true
        defer { isEngineBusy = false }

        kit.segmentDiscoveryCallback = { [weak self] segments in
            guard let last = segments.last, duration > 0 else { return }
            let fraction = min(max(Double(last.end) / duration, 0), 1)
            Task { @MainActor [weak self] in
                self?.updatePhase(jobID, .transcribing(fraction))
            }
        }
        defer { kit.segmentDiscoveryCallback = nil }

        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(
                audioPath: wavURL.path,
                decodeOptions: WhisperTranscriptionOptions.multilingual,
                callback: { _ in cancellationFlag.isSet ? false : true }
            )
        } catch {
            if cancellationFlag.isSet {
                jobs.removeAll { $0.id == jobID }
            } else {
                fail(jobID, message: error.localizedDescription)
            }
            return
        }

        if cancellationFlag.isSet {
            jobs.removeAll { $0.id == jobID }
            return
        }

        let segments = settingsStore.chineseScriptPreference.normalizeSegments(
            results
                .flatMap { $0.segments }
                .compactMap { segment -> SubtitleSegment? in
                    let text = Self.cleanSegmentText(segment.text)
                    guard !text.isEmpty else { return nil }
                    return SubtitleSegment(start: Double(segment.start), end: Double(segment.end), text: text)
                },
            languageCode: results.first?.language
        )

        let transcript = FileTranscript(
            fileName: mediaURL.lastPathComponent,
            sourcePath: mediaURL.path,
            durationSeconds: duration,
            text: segments.map(\.text).joined(separator: " "),
            segments: segments,
            modelName: modelManager.currentlyLoadedModel?.displayName ?? "Unknown",
            language: results.first?.language
        )
        modelContext.insert(transcript)
        try? modelContext.save()

        // Subtitle files land next to the media: the export folder for
        // remote jobs, the source file's folder for local ones.
        let subtitleFolder: URL
        switch job.source {
        case .remote(_, let exportFolder): subtitleFolder = exportFolder
        case .localFile(let url): subtitleFolder = url.deletingLastPathComponent()
        }
        let baseName = (mediaURL.lastPathComponent as NSString).deletingPathExtension

        if job.options.outputs.contains(.original) {
            let srtURL = subtitleFolder.appendingPathComponent(baseName + ".srt")
            do {
                try SubtitleExporter.write(SubtitleExporter.srt(segments), to: srtURL)
            } catch {
                fail(jobID, message: String(
                    localized: "files.srtWriteFailed",
                    defaultValue: "Transcript saved, but writing the .srt failed: \(error.localizedDescription)"
                ))
                return
            }
        }

        if job.options.translationTargets.isEmpty {
            jobs.removeAll { $0.id == jobID }
        } else {
            // Hand off to the UI for translation; the job row stays visible
            // in the .translating phase until the UI reports back.
            updatePhase(jobID, .translating(language: nil, progress: nil))
            pendingAutoTranslations.append(AutoTranslationRequest(
                id: jobID,
                transcriptID: transcript.id,
                targets: job.options.translationTargets,
                outputs: job.options.outputs,
                subtitleFolder: subtitleFolder,
                baseName: baseName
            ))
        }
    }

    /// Applies download progress only while the job is still downloading, so
    /// late callbacks cannot clobber a later phase.
    private func updateDownloadProgress(_ jobID: UUID, _ fraction: Double?) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              case .downloading = jobs[index].phase else { return }
        jobs[index].phase = .downloading(fraction)
    }

    /// Strips Whisper special tokens such as `<|0.00|>` or `<|zh|>`.
    private static func cleanSegmentText(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updatePhase(_ jobID: UUID, _ phase: Phase) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].phase = phase
    }

    private func fail(_ jobID: UUID, message: String) {
        updatePhase(jobID, .failed(message))
    }

    // MARK: - App Nap prevention

    private func beginActivity() {
        guard activityToken == nil else { return }
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Transcribing media files"
        )
    }

    private func endActivity() {
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }
}
