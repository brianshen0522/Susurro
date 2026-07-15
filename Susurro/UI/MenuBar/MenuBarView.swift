import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appController: AppController
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var navigation: NavigationModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            modelStatusSection
            Divider()
            actionSection
            Divider()
            navigationSection
            Divider()
            Button(String(localized: "menu.quit", defaultValue: "Quit Susurro")) {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
            .padding(.vertical, 2)
        }
        .frame(minWidth: 220)
    }

    private var modelStatusSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let loaded = modelManager.currentlyLoadedModel {
                Label(loaded.displayName, systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(String(localized: "menu.noModel", defaultValue: "No model loaded"), systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appController.dictationState == .recording {
                Button(String(localized: "menu.stopDictation", defaultValue: "Stop Dictation")) {
                    appController.stopDictation()
                }
                .padding(.vertical, 2)
            } else {
                Button(String(localized: "menu.startDictation", defaultValue: "Start Dictation")) {
                    appController.startDictation()
                }
                .disabled(appController.dictationState != .idle)
                .padding(.vertical, 2)
            }

            Menu(String(localized: "menu.switchModel", defaultValue: "Switch Model")) {
                ForEach(modelManager.availableModels) { size in
                    let status = modelManager.modelStatuses[size] ?? .notDownloaded
                    if case .downloaded = status {
                        Button(size.displayName) {
                            Task { try? await modelManager.load(size) }
                        }
                    } else if case .loaded = status {
                        Button(size.displayName + " ✓") {}
                            .disabled(true)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 4)
    }

    private var navigationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(String(localized: "menu.openTranscript", defaultValue: "Open Transcript")) {
                navigation.selectedPage = .transcript
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .padding(.vertical, 2)

            Button(String(localized: "menu.settings", defaultValue: "Settings")) {
                navigation.selectedPage = .settings
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .padding(.vertical, 2)
        }
        .padding(.horizontal, 4)
    }
}
