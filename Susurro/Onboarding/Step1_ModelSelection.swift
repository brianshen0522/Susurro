import SwiftUI

struct Step1ModelSelectionView: View {
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var settingsStore: SettingsStore
    @Binding var canProceed: Bool

    @State private var testResult: String?
    @State private var isTesting = false
    @State private var openAIKey = ""
    @State private var apiKeyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                VStack(spacing: 0) {
                    ForEach(modelManager.availableModels) { size in
                        OnboardingModelRow(
                            size: size,
                            status: modelManager.modelStatuses[size] ?? .notDownloaded,
                            isLoaded: modelManager.currentlyLoadedModel == size,
                            onDownload: {
                                try await modelManager.download(size)
                                updateCanProceed()
                            },
                            onCancelDownload: { modelManager.cancelDownload(size) },
                            onLoad: {
                                try await modelManager.load(size)
                                updateCanProceed()
                            },
                            onUnload: {
                                await modelManager.unloadCurrentModel()
                                updateCanProceed()
                            }
                        )
                        if size != modelManager.availableModels.last {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                openAISection
            }
            .padding(24)
        }
        .onChange(of: modelManager.currentlyLoadedModel) { _, _ in updateCanProceed() }
        .onChange(of: settingsStore.transcriptionSource) { _, _ in updateCanProceed() }
        .onAppear { updateCanProceed() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "onboarding.step1.title", defaultValue: "Choose Your Model"))
                .font(.title2.bold())
            Text(String(localized: "onboarding.step1.subtitle", defaultValue: "Select a local Whisper model to download, or use the OpenAI API. Larger models are more accurate but require more memory."))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var openAISection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "onboarding.step1.orOpenAI", defaultValue: "— or use OpenAI API —"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(String(localized: "onboarding.step1.useOpenAI", defaultValue: "Use OpenAI Whisper API"), isOn: Binding(
                        get: { settingsStore.transcriptionSource == .openAIAPI },
                        set: { settingsStore.transcriptionSource = $0 ? .openAIAPI : .local }
                    ))

                    if settingsStore.transcriptionSource == .openAIAPI {
                        SecureField(String(localized: "settings.apiKey", defaultValue: "OpenAI API Key"), text: $openAIKey)
                            .textFieldStyle(.roundedBorder)

                        if let err = apiKeyError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Button(String(localized: "settings.saveAPIKey", defaultValue: "Save API Key")) {
                            do {
                                try settingsStore.saveOpenAIKey(openAIKey)
                                apiKeyError = nil
                                updateCanProceed()
                            } catch {
                                apiKeyError = error.localizedDescription
                            }
                        }
                        .disabled(openAIKey.isEmpty)
                    }
                }
            }
        }
    }

    private func updateCanProceed() {
        canProceed = modelManager.currentlyLoadedModel != nil
            || (settingsStore.transcriptionSource == .openAIAPI && settingsStore.loadOpenAIKey() != nil)
    }
}

struct OnboardingModelRow: View {
    let size: WhisperModelSize
    let status: ModelManager.ModelStatus
    let isLoaded: Bool
    let onDownload: () async throws -> Void
    let onCancelDownload: () -> Void
    let onLoad: () async throws -> Void
    let onUnload: () async -> Void

    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(size.displayName)
                            .font(.system(size: 13, weight: .medium))
                        if isLoaded {
                            Text(String(localized: "model.loaded", defaultValue: "Loaded"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    HStack(spacing: 5) {
                        Text(String(localized: "model.multilingual", defaultValue: "Multilingual"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .foregroundStyle(Color.blue)
                            .clipShape(Capsule())
                    }
                    Text("\(size.approxDiskSizeMB) MB · ~\(size.approxRAMUsageMB) MB RAM")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                rowButton
            }

            if case .downloading(let progress) = status {
                ModelDownloadProgressView(progress: progress)
            } else if case .loading = status {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var rowButton: some View {
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
            Button(String(localized: "cancel", defaultValue: "Cancel"), action: onCancelDownload)
                .controlSize(.small)
        case .loading:
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 60)
        case .downloaded:
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
        case .loaded:
            Button(String(localized: "model.unload", defaultValue: "Unload")) {
                Task { await onUnload() }
            }
            .controlSize(.small)
        }
    }
}
