import SwiftUI

struct Step3GeneralSettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @Binding var canProceed: Bool
    @AppStorage("showInMenuBar") private var showInMenuBar = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                Form {
                    Section {
                        Toggle(String(localized: "settings.launchAtLogin", defaultValue: "Launch at Login"), isOn: $settingsStore.launchAtLogin)
                        Toggle(
                            String(localized: "settings.showInMenuBar", defaultValue: "Show in Menu Bar"),
                            isOn: $showInMenuBar
                        )
                    }

                    Section(String(localized: "settings.appearance", defaultValue: "Appearance")) {
                        Picker(String(localized: "settings.theme", defaultValue: "Theme"), selection: $settingsStore.theme) {
                            ForEach(AppTheme.allCases) { theme in
                                Text(theme.displayName).tag(theme)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    Section(String(localized: "settings.textInsertion", defaultValue: "Text Insertion")) {
                        Picker(String(localized: "settings.insertionMode", defaultValue: "Method"), selection: $settingsStore.textInsertionModeRaw) {
                            ForEach(TextInsertionMode.allCases) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.displayName)
                                    Text(mode == .simulateTyping
                                         ? String(localized: "insertion.simulateTyping.desc", defaultValue: "Types text character by character. Works in most apps.")
                                         : String(localized: "insertion.pasteboard.desc", defaultValue: "Uses clipboard paste. Faster but temporarily replaces clipboard.")
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.radioGroup)
                    }

                    Section(String(localized: "settings.audio", defaultValue: "Audio")) {
                        Toggle(String(localized: "settings.soundFeedback", defaultValue: "Play sound on start/stop"), isOn: $settingsStore.playSoundOnStartStop)
                    }
                }
                .formStyle(.grouped)
            }
            .padding(24)
        }
        .onAppear { canProceed = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "onboarding.step3.title", defaultValue: "General Settings"))
                .font(.title2.bold())
            Text(String(localized: "onboarding.step3.subtitle", defaultValue: "Configure how Susurro behaves. You can always change these later."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
