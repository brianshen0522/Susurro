import AppKit
import Combine
import SwiftData
import SwiftUI

@main
struct SusurroApp: App {
    @AppStorage("showInMenuBar") private var showInMenuBar = true
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var modelManager = ModelManager()
    @StateObject private var overlayController = OverlayController()
    @StateObject private var appControllerWrapper: AppControllerWrapper
    @StateObject private var navigationModel = NavigationModel()
    @StateObject private var fileTranscriptionService: FileTranscriptionService
    @StateObject private var updateManager = UpdateManager()
    let sharedModelContainer: ModelContainer

    init() {
        let schema = Schema([TranscriptEntry.self, FileTranscript.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        let modelContainer: ModelContainer
        do {
            modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }

        let settings = SettingsStore()
        let models = ModelManager()
        let overlay = OverlayController()
        let historyStore = HistoryStore(modelContext: modelContainer.mainContext)
        let wrapper = AppControllerWrapper(
            settings: settings,
            models: models,
            historyStore: historyStore
        )
        let fileService = FileTranscriptionService(
            modelManager: models,
            modelContext: modelContainer.mainContext,
            settingsStore: settings
        )
        fileService.appController = wrapper.controller
        wrapper.controller.fileTranscriptionService = fileService

        sharedModelContainer = modelContainer
        _settingsStore = StateObject(wrappedValue: settings)
        _modelManager = StateObject(wrappedValue: models)
        _overlayController = StateObject(wrappedValue: overlay)
        _appControllerWrapper = StateObject(wrappedValue: wrapper)
        _fileTranscriptionService = StateObject(wrappedValue: fileService)

        overlay.setup(appController: wrapper.controller)
    }

    var appController: AppController { appControllerWrapper.controller }

    var body: some Scene {
        // The main window is a WindowGroup so the system reopens it when the
        // Dock icon is clicked with no windows open — the app must stay
        // reachable even when the menu bar icon is disabled or unavailable.
        WindowGroup(String(localized: "window.main", defaultValue: "Susurro"), id: "main") {
            MainWindowRootView()
                .environmentObject(appController)
                .environmentObject(modelManager)
                .environmentObject(settingsStore)
                .environmentObject(navigationModel)
                .environmentObject(fileTranscriptionService)
                .environmentObject(updateManager)
                .modelContainer(sharedModelContainer)
        }
        .defaultSize(width: 860, height: 620)
        .defaultPosition(.center)
        .commands {
            SusurroCommands(navigation: navigationModel, updateManager: updateManager)
            // Keep the app single-window: no File > New Window.
            CommandGroup(replacing: .newItem) {}
        }

        Window(String(localized: "window.about", defaultValue: "About Susurro"), id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarView()
                .environmentObject(appController)
                .environmentObject(modelManager)
                .environmentObject(settingsStore)
                .environmentObject(navigationModel)
        } label: {
            MenuBarIconView(state: appController.dictationState)
        }
    }
}

/// Shows the onboarding wizard on first run, then the dashboard in the same
/// window once setup is complete.
struct MainWindowRootView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    var body: some View {
        if hasCompletedOnboarding {
            DashboardView()
        } else {
            OnboardingView()
        }
    }
}

struct SusurroCommands: Commands {
    let navigation: NavigationModel
    let updateManager: UpdateManager
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(String(localized: "menu.about", defaultValue: "About Susurro")) {
                openWindow(id: "about")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button(String(localized: "menu.checkUpdates", defaultValue: "Check for Updates…")) {
                updateManager.checkForUpdates()
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "menu.settings", defaultValue: "Settings…")) {
                navigation.selectedPage = .settings
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

}

@MainActor
final class AppControllerWrapper: ObservableObject {
    let controller: AppController

    init(settings: SettingsStore, models: ModelManager, historyStore: HistoryStore) {
        controller = AppController(
            modelManager: models,
            settingsStore: settings,
            historyStore: historyStore
        )
    }
}

struct MenuBarIconView: View {
    let state: DictationState

    var body: some View {
        switch state {
        case .idle:
            Image(systemName: "waveform.circle")
        case .recording:
            Image(systemName: "waveform.circle.fill")
                .symbolEffect(.variableColor.iterative.reversing)
                .foregroundStyle(.red)
        case .processing:
            Image(systemName: "waveform.circle.fill")
                .symbolEffect(.pulse)
                .foregroundStyle(.blue)
        case .error:
            Image(systemName: "waveform.circle.fill")
                .foregroundStyle(.orange)
        }
    }
}
