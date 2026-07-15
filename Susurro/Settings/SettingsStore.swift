import Combine
import Foundation
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false {
        didSet { updateLaunchAtLogin() }
    }
    @AppStorage("theme") var theme: AppTheme = .system
    @AppStorage("transcriptionSource") var transcriptionSourceRaw: String = TranscriptionSource.local.rawValue
    @AppStorage("defaultModel") var defaultModelRaw: String = ""
    @AppStorage("hotkeyKey") var hotkeyKeyRaw: String = HotkeyKey.fn.rawValue
    @AppStorage("playSoundOnStartStop") var playSoundOnStartStop: Bool = true
    @AppStorage("pauseMediaDuringDictation") var pauseMediaDuringDictation: Bool = true
    @AppStorage("textInsertionMode") var textInsertionModeRaw: String = TextInsertionMode.simulateTyping.rawValue
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false

    var transcriptionSource: TranscriptionSource {
        get { TranscriptionSource(rawValue: transcriptionSourceRaw) ?? .local }
        set { transcriptionSourceRaw = newValue.rawValue }
    }

    /// The model loaded automatically when the app starts (e.g. at login).
    /// `nil` means no model is loaded until the user picks one manually.
    var defaultModel: WhisperModelSize? {
        get { WhisperModelSize(rawValue: defaultModelRaw) }
        set { defaultModelRaw = newValue?.rawValue ?? "" }
    }

    var hotkeyKey: HotkeyKey {
        get { HotkeyKey(rawValue: hotkeyKeyRaw) ?? .fn }
        set { hotkeyKeyRaw = newValue.rawValue }
    }

    var textInsertionMode: TextInsertionMode {
        get { TextInsertionMode(rawValue: textInsertionModeRaw) ?? .simulateTyping }
        set { textInsertionModeRaw = newValue.rawValue }
    }

    var hotkeyMode: HotkeyTriggerMode {
        get { .pressAndHold(key: hotkeyKey) }
        set {
            if case .pressAndHold(let key) = newValue {
                hotkeyKeyRaw = key.rawValue
            }
        }
    }

    func saveOpenAIKey(_ key: String) throws {
        try KeychainHelper.save(key: "openai_api_key", value: key)
    }

    func loadOpenAIKey() -> String? {
        try? KeychainHelper.load(key: "openai_api_key")
    }

    func deleteOpenAIKey() throws {
        try KeychainHelper.delete(key: "openai_api_key")
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
        }
    }
}
