import AppKit
import AVFoundation
import Combine
import Foundation
import SwiftUI

enum DictationState: Equatable {
    case idle
    case recording
    case processing
    case error(String)
}

@MainActor
final class AppController: ObservableObject {
    @Published var dictationState: DictationState = .idle
    @Published var audioLevel: Float = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasMicrophonePermission = false

    let modelManager: ModelManager
    let settingsStore: SettingsStore
    let hotkeyManager: HotkeyManager
    let textInjector: TextInjector
    let mediaPlaybackController = MediaPlaybackController()
    // Owned by SusurroApp; weak to avoid a retain cycle with the service's
    // back-reference used for dictation-priority coordination.
    weak var fileTranscriptionService: FileTranscriptionService?

    private let audioEngine: AudioEngine
    private let historyStore: HistoryStore
    private var cancellables = Set<AnyCancellable>()
    private var recordingStartTime: Date?
    private var transcriptionEngine: (any TranscriptionEngine)?
    private var permissionRefreshTask: Task<Void, Never>?
    private var isHotkeyMonitoringSuspended = false

    init(modelManager: ModelManager, settingsStore: SettingsStore, historyStore: HistoryStore) {
        self.modelManager = modelManager
        self.settingsStore = settingsStore
        self.historyStore = historyStore
        self.hotkeyManager = HotkeyManager()
        self.audioEngine = AudioEngine()
        self.textInjector = TextInjector()

        audioEngine.audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .assign(to: \.audioLevel, on: self)
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshPermissions()
                self?.schedulePermissionRefresh()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)
            .first()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.startHotkeyMonitoring()
                self?.refreshPermissions()
                self?.autoLoadDefaultModel()
            }
            .store(in: &cancellables)

        updateTranscriptionEngine()
    }

    func refreshPermissions() {
        // Lifecycle callbacks such as onAppear can run while SwiftUI is still
        // reconciling a view. Publish on the following actor turn instead.
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.permissionRefreshTask = nil
            self.applyPermissionSnapshot()
        }
    }

    private func applyPermissionSnapshot() {
        let accessibilityGranted = hotkeyManager.hasAccessibilityPermission
        let microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        if hasAccessibilityPermission != accessibilityGranted {
            hasAccessibilityPermission = accessibilityGranted
        }
        if hasMicrophonePermission != microphoneGranted {
            hasMicrophonePermission = microphoneGranted
        }

        // A tap created before Accessibility was granted fails. Recreate it
        // after returning from System Settings, but never tear down a healthy
        // tap based on a separate permission preflight.
        if accessibilityGranted && !isHotkeyMonitoringSuspended && !hotkeyManager.isMonitoring {
            hotkeyManager.startMonitoring()
        }
    }

    func requestAccessibilityPermission() {
        hotkeyManager.requestAccessibilityPermission()
        refreshPermissions()
        schedulePermissionRefresh()
    }

    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshPermissions()
                }
            }
        case .denied, .restricted:
            openPrivacySettings(pane: "Privacy_Microphone")
        case .authorized:
            refreshPermissions()
        @unknown default:
            refreshPermissions()
        }
    }

    func openAccessibilitySettings() {
        openPrivacySettings(pane: "Privacy_Accessibility")
    }

    func openMicrophoneSettings() {
        openPrivacySettings(pane: "Privacy_Microphone")
    }

    private func schedulePermissionRefresh() {
        // TCC updates can arrive just after its prompt or System Settings opens.
        for delay in [0.25, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshPermissions()
            }
        }
    }

    private func openPrivacySettings(pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Loads the user's default model at startup (e.g. when launched at
    /// login) so dictation works without opening the main window first.
    private func autoLoadDefaultModel() {
        guard settingsStore.transcriptionSource == .local,
              modelManager.currentlyLoadedModel == nil,
              let model = settingsStore.defaultModel,
              case .downloaded = modelManager.modelStatuses[model] ?? .notDownloaded
        else { return }

        Task {
            do {
                try await modelManager.load(model)
            } catch {
                print("[AppController] Failed to auto-load default model \(model.rawValue): \(error)")
            }
        }
    }

    func updateTranscriptionEngine() {
        switch settingsStore.transcriptionSource {
        case .local:
            transcriptionEngine = WhisperKitEngine(modelManager: modelManager)
        case .openAIAPI:
            transcriptionEngine = OpenAIWhisperEngine(settingsStore: settingsStore)
        }
    }

    func startHotkeyMonitoring() {
        guard !isHotkeyMonitoringSuspended else { return }
        hotkeyManager.delegate = self
        hotkeyManager.updateConfiguration(settingsStore.hotkeyMode)
        hotkeyManager.startMonitoring()
    }

    func stopHotkeyMonitoring() {
        hotkeyManager.stopMonitoring()
    }

    func suspendHotkeyMonitoring() {
        isHotkeyMonitoringSuspended = true
        hotkeyManager.stopMonitoring()
    }

    func resumeHotkeyMonitoring() {
        isHotkeyMonitoringSuspended = false
        startHotkeyMonitoring()
    }

    func startDictation() {
        guard dictationState == .idle else { return }

        // Dictation and file transcription share the loaded WhisperKit
        // instance; concurrent transcribe calls are not safe.
        if settingsStore.transcriptionSource == .local, fileTranscriptionService?.isEngineBusy == true {
            dictationState = .error(String(
                localized: "error.engineBusy",
                defaultValue: "A file is being transcribed. Try again when it finishes."
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .error = self.dictationState {
                    self.dictationState = .idle
                }
            }
            return
        }

        if settingsStore.transcriptionSource == .local && modelManager.currentlyLoadedModel == nil {
            dictationState = .error(String(localized: "error.noModelLoaded", defaultValue: "No model loaded. Please load a model from the Dashboard."))
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .error = self.dictationState {
                    self.dictationState = .idle
                }
            }
            return
        }

        // Stop music/video before the mic opens so it doesn't bleed into
        // the recording; resumed once the dictation round-trip finishes.
        if settingsStore.pauseMediaDuringDictation {
            mediaPlaybackController.pauseNowPlaying()
        }

        do {
            try audioEngine.startRecording()
            recordingStartTime = Date()
            dictationState = .recording
        } catch {
            mediaPlaybackController.resumePaused()
            dictationState = .error(error.localizedDescription)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if case .error = self.dictationState {
                    self.dictationState = .idle
                }
            }
        }
    }

    func stopDictation() {
        guard dictationState == .recording else { return }

        guard let buffer = audioEngine.stopRecording() else {
            dictationState = .idle
            mediaPlaybackController.resumePaused()
            return
        }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        dictationState = .processing

        Task {
            do {
                guard let engine = transcriptionEngine else {
                    throw TranscriptionError.noModelLoaded
                }
                let text = try await engine.transcribe(audio: buffer)

                try await MainActor.run {
                    self.dictationState = .idle
                    self.mediaPlaybackController.resumePaused()
                    guard !text.isEmpty else { return }
                    self.textInjector.insert(text: text, mode: self.settingsStore.textInsertionMode)

                    let entry = TranscriptEntry(
                        text: text,
                        timestamp: Date(),
                        durationSeconds: duration,
                        sourceDescription: self.sourceDescription
                    )
                    try self.historyStore.save(entry)
                }
            } catch {
                await MainActor.run {
                    self.dictationState = .error(error.localizedDescription)
                    self.mediaPlaybackController.resumePaused()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if case .error = self.dictationState {
                            self.dictationState = .idle
                        }
                    }
                }
            }
        }
    }

    func cancelDictation() {
        guard dictationState == .recording else { return }
        audioEngine.discardRecording()
        recordingStartTime = nil
        dictationState = .idle
        mediaPlaybackController.resumePaused()
    }

    private var sourceDescription: String {
        switch settingsStore.transcriptionSource {
        case .local:
            let size = modelManager.currentlyLoadedModel?.displayName ?? "Unknown"
            return "Whisper \(size)"
        case .openAIAPI:
            return "OpenAI API"
        }
    }
}

extension AppController: HotkeyManagerDelegate {
    func hotkeyDidTriggerStart() {
        startDictation()
    }

    func hotkeyDidTriggerStop() {
        stopDictation()
    }
}
