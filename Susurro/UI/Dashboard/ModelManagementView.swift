import AVFoundation
import SwiftUI
import WhisperKit

/// Model download / load management, rendered as a Form section inside the
/// Settings page.
struct ModelsSettingsSection: View {
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var settingsStore: SettingsStore
    @State private var testResult: String?
    @State private var testError: String?
    @State private var isTesting: Bool = false
    @State private var testCountdown: Int = 0
    @State private var countdownTimer: Timer?

    var body: some View {
        Section(String(localized: "settings.models", defaultValue: "Models")) {
            defaultModelPicker

            ForEach(modelManager.availableModels) { size in
                ModelRowView(
                    size: size,
                    status: modelManager.modelStatuses[size] ?? .notDownloaded,
                    isCurrentlyLoaded: modelManager.currentlyLoadedModel == size,
                    onDownload: { try await modelManager.download(size) },
                    onCancelDownload: { modelManager.cancelDownload(size) },
                    onLoad: { try await modelManager.load(size) },
                    onUnload: { await modelManager.unloadCurrentModel() },
                    onDelete: { try modelManager.delete(size) },
                    onTest: modelManager.currentlyLoadedModel == size ? { runTest() } : nil,
                    isTesting: isTesting
                )
            }

            if isTesting {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(testCountdown > 0
                         ? String(localized: "model.testRecording", defaultValue: "Recording… \(testCountdown)s")
                         : String(localized: "model.testTranscribing", defaultValue: "Transcribing…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if let result = testResult {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "model.testResult", defaultValue: "Test Result:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(result.isEmpty
                         ? String(localized: "model.testEmpty", defaultValue: "(no speech detected)")
                         : result)
                        .font(.caption)
                        .foregroundStyle(result.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            }

            if let err = testError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var defaultModelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(
                String(localized: "settings.defaultModel", defaultValue: "Default Model"),
                selection: $settingsStore.defaultModelRaw
            ) {
                Text(String(localized: "settings.defaultModel.none", defaultValue: "None"))
                    .tag("")
                ForEach(defaultModelChoices) { size in
                    Text(defaultModelLabel(for: size)).tag(size.rawValue)
                }
            }
            Text(String(
                localized: "settings.defaultModel.hint",
                defaultValue: "Loaded automatically when Susurro starts, so dictation is ready right away."
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Only downloaded models can be auto-loaded. Keep the saved choice
    /// visible even if its files were deleted so the selection isn't lost.
    private var defaultModelChoices: [WhisperModelSize] {
        var choices = modelManager.availableModels.filter { isDownloaded($0) }
        if let current = settingsStore.defaultModel, !choices.contains(current) {
            choices.append(current)
        }
        return choices
    }

    private func isDownloaded(_ size: WhisperModelSize) -> Bool {
        switch modelManager.modelStatuses[size] {
        case .downloaded, .loading, .loaded: return true
        default: return false
        }
    }

    private func defaultModelLabel(for size: WhisperModelSize) -> String {
        isDownloaded(size)
            ? size.displayName
            : size.displayName + " " + String(localized: "settings.defaultModel.notDownloaded", defaultValue: "(not downloaded)")
    }

    private func runTest() {
        guard !isTesting else { return }
        testResult = nil
        testError = nil
        isTesting = true
        testCountdown = 3

        let audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        let whisperFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

        var collectedBuffers: [AVAudioPCMBuffer] = []

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { buf, _ in
            guard let converter = AVAudioConverter(from: hardwareFormat, to: whisperFormat) else { return }
            let ratio = whisperFormat.sampleRate / hardwareFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: outCap) else { return }
            var inputConsumed = false
            converter.convert(to: outBuf, error: nil) { _, status in
                if inputConsumed { status.pointee = .noDataNow; return nil }
                status.pointee = .haveData; inputConsumed = true; return buf
            }
            collectedBuffers.append(outBuf)
        }

        try? audioEngine.start()

        countdownTimer?.invalidate()
        var remaining = 3
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            remaining -= 1
            testCountdown = remaining
            if remaining <= 0 { timer.invalidate() }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            countdownTimer?.invalidate()
            testCountdown = 0

            let totalFrames = collectedBuffers.reduce(0) { $0 + $1.frameLength }
            guard totalFrames > 0,
                  let merged = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: totalFrames) else {
                isTesting = false
                testError = "No audio captured"
                return
            }
            merged.frameLength = totalFrames
            var offset: AVAudioFrameCount = 0
            for buf in collectedBuffers {
                guard let src = buf.floatChannelData, let dst = merged.floatChannelData else { continue }
                dst[0].advanced(by: Int(offset)).initialize(from: src[0], count: Int(buf.frameLength))
                offset += buf.frameLength
            }

            Task {
                do {
                    guard let kit = modelManager.getWhisperKit() else {
                        await MainActor.run { isTesting = false; testError = "Model not loaded" }
                        return
                    }
                    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                    defer { try? FileManager.default.removeItem(at: tmpURL) }
                    let file = try AVAudioFile(forWriting: tmpURL, settings: whisperFormat.settings)
                    try file.write(from: merged)
                    let results = try await kit.transcribe(
                        audioPath: tmpURL.path,
                        decodeOptions: WhisperTranscriptionOptions.multilingual
                    )
                    let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                    await MainActor.run { isTesting = false; testResult = text }
                } catch {
                    await MainActor.run { isTesting = false; testError = error.localizedDescription }
                }
            }
        }
    }
}

struct ModelRowView: View {
    let size: WhisperModelSize
    let status: ModelManager.ModelStatus
    let isCurrentlyLoaded: Bool
    let onDownload: () async throws -> Void
    let onCancelDownload: () -> Void
    let onLoad: () async throws -> Void
    let onUnload: () async -> Void
    let onDelete: () throws -> Void
    var onTest: (() -> Void)? = nil
    var isTesting: Bool = false

    @State private var showDeleteConfirm = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(size.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if isCurrentlyLoaded {
                            Text(String(localized: "model.loaded", defaultValue: "Loaded"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(sizeInfo)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                actionButtons
            }

            if case .downloading(let progress) = status {
                ModelDownloadProgressView(progress: progress)
            } else if case .loading = status {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }

            if let err = error {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            String(localized: "model.deleteConfirm", defaultValue: "Delete \(size.displayName)?"),
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                do {
                    try onDelete()
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private var sizeInfo: String {
        "\(size.approxDiskSizeMB) MB disk · \(size.approxRAMUsageMB) MB RAM"
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch status {
        case .notDownloaded:
            Button(String(localized: "model.download", defaultValue: "Download")) {
                error = nil
                Task {
                    do {
                        try await onDownload()
                    } catch is CancellationError {
                        // User-initiated cancellation is not an error.
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .downloading:
            Button(String(localized: "cancel", defaultValue: "Cancel")) {
                onCancelDownload()
            }
            .controlSize(.small)

        case .loading:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 60)

        case .downloaded:
            HStack(spacing: 6) {
                Button(String(localized: "model.load", defaultValue: "Load")) {
                    error = nil
                    Task {
                        do {
                            try await onLoad()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                    showDeleteConfirm = true
                }
                .controlSize(.small)
            }

        case .loaded:
            HStack(spacing: 6) {
                if let onTest {
                    Button(String(localized: "model.test", defaultValue: "Test")) {
                        onTest()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isTesting)
                }

                Button(String(localized: "model.unload", defaultValue: "Unload")) {
                    Task { await onUnload() }
                }
                .controlSize(.small)

                Button(String(localized: "delete", defaultValue: "Delete"), role: .destructive) {
                    showDeleteConfirm = true
                }
                .controlSize(.small)
            }
        }
    }
}
