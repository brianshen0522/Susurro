import SwiftData
import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var appController: AppController
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var navigation: NavigationModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch navigation.selectedPage {
            case .transcript:
                HistoryListView()
            case .files:
                FileTranscriptionView()
            case .settings:
                SettingsView()
            }
        }
    }

    private var sidebar: some View {
        List(selection: selectedPageBinding) {
            ForEach(MainPage.allCases) { page in
                Label(page.title, systemImage: page.systemImage)
                    .tag(page)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        .safeAreaInset(edge: .bottom) {
            statusFooter
        }
    }

    // List selection wants an Optional; the app always has a current page.
    private var selectedPageBinding: Binding<MainPage?> {
        Binding(
            get: { navigation.selectedPage },
            set: { newValue in
                if let newValue {
                    navigation.selectedPage = newValue
                }
            }
        )
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
            }
            if let loaded = modelManager.currentlyLoadedModel {
                Text(loaded.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(String(format: "%.0f MB RAM", modelManager.currentRAMUsageMB))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text(String(localized: "dashboard.noModelLoaded", defaultValue: "No model loaded"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .padding(.top, 2)
    }

    private var statusColor: Color {
        switch appController.dictationState {
        case .idle: return modelManager.currentlyLoadedModel != nil ? .green : .orange
        case .recording: return .red
        case .processing: return .blue
        case .error: return .red
        }
    }

    private var statusText: String {
        switch appController.dictationState {
        case .idle:
            return modelManager.currentlyLoadedModel != nil
                ? String(localized: "status.ready", defaultValue: "Ready")
                : String(localized: "status.noModel", defaultValue: "No Model")
        case .recording:
            return String(localized: "status.recording", defaultValue: "Recording")
        case .processing:
            return String(localized: "status.processing", defaultValue: "Processing")
        case .error:
            return String(localized: "status.error", defaultValue: "Error")
        }
    }
}
