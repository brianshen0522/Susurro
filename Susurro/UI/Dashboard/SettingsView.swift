import AVFoundation
import SwiftUI

/// The Settings page shown in the main window's detail area. Includes model
/// download / load management alongside the app preferences.
struct SettingsView: View {
    @EnvironmentObject var appController: AppController
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var updateManager: UpdateManager
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    @State private var openAIKey: String = ""
    @State private var apiKeyVisible = false
    @State private var apiKeySaved = false
    @State private var isMicTesting: Bool = false
    @State private var micLevel: Float = 0
    @State private var micTestEngine: AVAudioEngine? = nil

    var body: some View {
        Form {
            transcriptionSection
            ModelsSettingsSection()
                .environmentObject(modelManager)
            hotkeySection
            permissionsSection
            micTestSection
            textInsertionSection
            generalSection
            updatesSection
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .onAppear {
            openAIKey = settingsStore.loadOpenAIKey() ?? ""
            appController.refreshPermissions()
        }
    }

    private var hotkeySection: some View {
        Section(String(localized: "settings.hotkey", defaultValue: "Hotkey")) {
            Picker(String(localized: "settings.hotkeyKey", defaultValue: "Key"), selection: $settingsStore.hotkeyKeyRaw) {
                ForEach(HotkeyKey.allCases) { key in
                    Text(key.displayName).tag(key.rawValue)
                }
            }
            .onChange(of: settingsStore.hotkeyKeyRaw) { _, _ in
                appController.hotkeyManager.updateConfiguration(settingsStore.hotkeyMode)
            }

            Text(String(localized: "settings.hotkeyHint", defaultValue: "Hold the key to record. Release to stop."))
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    private var permissionsSection: some View {
        Section(String(localized: "settings.permissions", defaultValue: "Permissions")) {
            permissionRow(
                title: String(localized: "permission.accessibility", defaultValue: "Accessibility"),
                description: String(
                    localized: "permission.accessibility.desc",
                    defaultValue: "Required for the global hotkey and text insertion."
                ),
                isGranted: appController.hasAccessibilityPermission,
                requestAction: appController.requestAccessibilityPermission,
                settingsAction: appController.openAccessibilitySettings
            )
            permissionRow(
                title: String(localized: "permission.microphone", defaultValue: "Microphone"),
                description: String(localized: "permission.microphone.desc", defaultValue: "Required to record your voice."),
                isGranted: appController.hasMicrophonePermission,
                requestAction: appController.requestMicrophonePermission,
                settingsAction: appController.openMicrophoneSettings
            )
            Button(String(localized: "settings.recheck", defaultValue: "Recheck Permissions")) {
                appController.refreshPermissions()
            }
            .buttonStyle(.bordered)
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        isGranted: Bool,
        requestAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(isGranted ? Color.green : Color.red)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !isGranted {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(String(localized: "permission.grant", defaultValue: "Grant Access"), action: requestAction)
                    Button(String(localized: "permission.open", defaultValue: "Open Settings"), action: settingsAction)
                }
                .controlSize(.small)
            }
        }
    }

    private var micTestSection: some View {
        Section(String(localized: "settings.micTest", defaultValue: "Microphone")) {
            HStack(spacing: 12) {
                Button {
                    if isMicTesting { stopMicTest() } else { startMicTest() }
                } label: {
                    Label(
                        isMicTesting
                            ? String(localized: "settings.micTest.stop", defaultValue: "Stop Test")
                            : String(localized: "settings.micTest.start", defaultValue: "Test Microphone"),
                        systemImage: isMicTesting ? "stop.circle.fill" : "mic.circle"
                    )
                }
                .buttonStyle(.bordered)
                .tint(isMicTesting ? .red : .accentColor)

                if isMicTesting {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(levelColor(micLevel))
                                .frame(width: geo.size.width * CGFloat(min(micLevel * 5, 1)))
                                .animation(.easeOut(duration: 0.05), value: micLevel)
                        }
                    }
                    .frame(height: 8)
                }
            }
            .padding(.vertical, 2)
            .onDisappear { stopMicTest() }
        }
    }

    private func levelColor(_ level: Float) -> Color {
        if level < 0.1 { return .green }
        if level < 0.18 { return .yellow }
        return .red
    }

    private func startMicTest() {
        let eng = AVAudioEngine()
        let input = eng.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
            guard let data = buf.floatChannelData else { return }
            let frames = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<frames { sum += data[0][i] * data[0][i] }
            let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
            DispatchQueue.main.async { self.micLevel = rms }
        }
        try? eng.start()
        micTestEngine = eng
        isMicTesting = true
    }

    private func stopMicTest() {
        micTestEngine?.inputNode.removeTap(onBus: 0)
        micTestEngine?.stop()
        micTestEngine = nil
        isMicTesting = false
        micLevel = 0
    }

    private var transcriptionSection: some View {
        Section(String(localized: "settings.transcription", defaultValue: "Transcription")) {
            Picker(String(localized: "settings.source", defaultValue: "Engine"), selection: $settingsStore.transcriptionSourceRaw) {
                Text(String(localized: "source.local", defaultValue: "Local (WhisperKit)")).tag(TranscriptionSource.local.rawValue)
                Text(String(localized: "source.openai", defaultValue: "OpenAI API")).tag(TranscriptionSource.openAIAPI.rawValue)
            }
            .onChange(of: settingsStore.transcriptionSourceRaw) { _, _ in
                appController.updateTranscriptionEngine()
            }

            Picker(
                String(localized: "settings.chineseScript", defaultValue: "Chinese Script"),
                selection: $settingsStore.chineseScriptPreferenceRaw
            ) {
                ForEach(ChineseScriptPreference.allCases) { preference in
                    Text(preference.displayName).tag(preference.rawValue)
                }
            }
            Text(String(
                localized: "settings.chineseScript.hint",
                defaultValue: "Whisper picks Traditional or Simplified at random. Choose one to convert every Chinese transcript to that script."
            ))
            .foregroundStyle(.secondary)
            .font(.caption)

            if settingsStore.transcriptionSource == .openAIAPI {
                HStack {
                    if apiKeyVisible {
                        TextField(String(localized: "settings.apiKey", defaultValue: "OpenAI API Key"), text: $openAIKey)
                    } else {
                        SecureField(String(localized: "settings.apiKey", defaultValue: "OpenAI API Key"), text: $openAIKey)
                    }
                    Button {
                        apiKeyVisible.toggle()
                    } label: {
                        Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                }

                Button(apiKeySaved
                       ? String(localized: "settings.apiKeySaved", defaultValue: "Saved!")
                       : String(localized: "settings.saveAPIKey", defaultValue: "Save API Key")) {
                    try? settingsStore.saveOpenAIKey(openAIKey)
                    apiKeySaved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        apiKeySaved = false
                    }
                }
                .disabled(openAIKey.isEmpty)
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var textInsertionSection: some View {
        Section(String(localized: "settings.textInsertion", defaultValue: "Text Insertion")) {
            Picker(String(localized: "settings.insertionMode", defaultValue: "Mode"), selection: $settingsStore.textInsertionModeRaw) {
                ForEach(TextInsertionMode.allCases) { mode in
                    Text(mode.displayName).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var updatesSection: some View {
        Section(String(localized: "settings.updates", defaultValue: "Updates")) {
            HStack {
                Text(String(
                    localized: "settings.currentVersion",
                    defaultValue: "Version \(updateManager.currentVersion) (beta)"
                ))
                .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "settings.checkUpdates", defaultValue: "Check for Updates…")) {
                    updateManager.checkForUpdates()
                }
            }
            Toggle(
                String(localized: "settings.autoUpdateCheck", defaultValue: "Check for Updates Automatically"),
                isOn: Binding(
                    get: { updateManager.automaticallyChecksForUpdates },
                    set: { updateManager.automaticallyChecksForUpdates = $0 }
                )
            )
            Toggle(
                String(localized: "settings.betaUpdates", defaultValue: "Receive Beta Updates"),
                isOn: $updateManager.receiveBetaUpdates
            )
        }
    }

    private var generalSection: some View {
        Section(String(localized: "settings.general", defaultValue: "General")) {
            Toggle(String(localized: "settings.launchAtLogin", defaultValue: "Launch at Login"), isOn: $settingsStore.launchAtLogin)
            Toggle(
                String(localized: "settings.pauseMedia", defaultValue: "Pause Music/Spotify/VLC While Dictating"),
                isOn: $settingsStore.pauseMediaDuringDictation
            )
            Toggle(
                String(localized: "settings.showInMenuBar", defaultValue: "Show in Menu Bar"),
                isOn: $showInMenuBar
            )

            Picker(String(localized: "settings.theme", defaultValue: "Appearance"), selection: $settingsStore.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
        }
    }
}
