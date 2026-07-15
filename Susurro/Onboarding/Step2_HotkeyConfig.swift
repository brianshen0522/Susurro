import SwiftUI

struct Step2HotkeyConfigView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var appController: AppController
    @Binding var canProceed: Bool

    @State private var liveStatus: String = ""
    @State private var liveTestDelegate: LiveTestDelegate?
    @State private var previewHotkeyManager: HotkeyManager?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker(String(localized: "settings.hotkeyKey", defaultValue: "Key"), selection: $settingsStore.hotkeyKeyRaw) {
                            ForEach(HotkeyKey.allCases) { key in
                                Text(key.displayName).tag(key.rawValue)
                            }
                        }
                        .onChange(of: settingsStore.hotkeyKeyRaw) { _, _ in applyHotkeyConfig() }

                        Text(String(localized: "settings.hotkeyHint", defaultValue: "Hold the key to record. Release to stop."))
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                permissionSection

                liveTestSection
            }
            .padding(24)
        }
        .onAppear {
            canProceed = true
            appController.refreshPermissions()
            setupLiveTest()
        }
        .onDisappear {
            tearDownLiveTest()
        }
        .onChange(of: appController.hasAccessibilityPermission) { _, isGranted in
            if isGranted {
                applyHotkeyConfig()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "onboarding.step2.title", defaultValue: "Configure Hotkey"))
                .font(.title2.bold())
            Text(String(localized: "onboarding.step2.subtitle", defaultValue: "Choose a key to trigger dictation. Hold to record, release to stop."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var permissionSection: some View {
        GroupBox(String(localized: "onboarding.permissions", defaultValue: "Permissions")) {
            VStack(alignment: .leading, spacing: 10) {
                PermissionRow(
                    title: String(localized: "permission.accessibility", defaultValue: "Accessibility"),
                    description: String(
                        localized: "permission.accessibility.desc",
                        defaultValue: "Required for the global hotkey and text insertion."
                    ),
                    isGranted: appController.hasAccessibilityPermission,
                    requestAction: appController.requestAccessibilityPermission,
                    settingsAction: appController.openAccessibilitySettings
                )
            }
        }
    }

    private var liveTestSection: some View {
        GroupBox(String(localized: "onboarding.liveTest", defaultValue: "Live Test")) {
            HStack {
                Image(systemName: "record.circle")
                    .foregroundStyle(liveStatus.isEmpty ? Color.secondary : Color.accentColor)
                Text(liveStatus.isEmpty
                     ? String(localized: "onboarding.liveTest.idle", defaultValue: "Hold your hotkey to test…")
                     : liveStatus)
                    .font(.system(size: 13))
                    .foregroundStyle(liveStatus.isEmpty ? .secondary : .primary)
                    .animation(.easeInOut, value: liveStatus)
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    private func setupLiveTest() {
        applyHotkeyConfig()
    }

    private func applyHotkeyConfig() {
        previewHotkeyManager?.stopMonitoring()
        appController.suspendHotkeyMonitoring()

        let manager = HotkeyManager()
        manager.updateConfiguration(settingsStore.hotkeyMode)
        let delegate = LiveTestDelegate { [self] status in
            liveStatus = status
        }
        liveTestDelegate = delegate
        manager.delegate = delegate
        previewHotkeyManager = manager
        manager.startMonitoring()
    }

    private func tearDownLiveTest() {
        previewHotkeyManager?.stopMonitoring()
        previewHotkeyManager = nil
        liveTestDelegate = nil
        appController.resumeHotkeyMonitoring()
    }
}

struct PermissionRow: View {
    let title: String
    let description: String
    let isGranted: Bool
    let requestAction: () -> Void
    let settingsAction: () -> Void

    init(
        title: String,
        description: String,
        isGranted: Bool,
        requestAction: @escaping () -> Void,
        settingsAction: @escaping () -> Void
    ) {
        self.title = title
        self.description = description
        self.isGranted = isGranted
        self.requestAction = requestAction
        self.settingsAction = settingsAction
    }

    var body: some View {
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
}

@MainActor
private final class LiveTestDelegate: HotkeyManagerDelegate {
    private let callback: (String) -> Void
    private var isRecording = false

    init(callback: @escaping (String) -> Void) {
        self.callback = callback
    }

    func hotkeyDidTriggerStart() {
        isRecording = true
        callback(String(localized: "liveTest.started", defaultValue: "Recording… release to stop."))
    }

    func hotkeyDidTriggerStop() {
        isRecording = false
        callback(String(localized: "liveTest.stopped", defaultValue: "Hotkey is working!"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.callback("")
        }
    }
}
