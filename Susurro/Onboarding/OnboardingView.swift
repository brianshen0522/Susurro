import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var modelManager: ModelManager
    @EnvironmentObject var appController: AppController

    @State private var currentStep = 0
    @State private var canProceed = false

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            TabView(selection: $currentStep) {
                Step1ModelSelectionView(canProceed: $canProceed)
                    .tag(0)
                    .environmentObject(modelManager)

                Step2HotkeyConfigView(canProceed: $canProceed)
                    .tag(1)
                    .environmentObject(settingsStore)
                    .environmentObject(appController)

                Step3GeneralSettingsView(canProceed: $canProceed)
                    .tag(2)
                    .environmentObject(settingsStore)
            }
            .tabViewStyle(.automatic)

            Divider()

            navigationBar
                .padding(16)
        }
        .frame(width: 560, height: 560)
        .onAppear { updateCanProceed() }
        .onChange(of: currentStep) { _, _ in updateCanProceed() }
    }

    private func updateCanProceed() {
        switch currentStep {
        case 0:
            canProceed = modelManager.currentlyLoadedModel != nil
                || settingsStore.transcriptionSource == .openAIAPI
        case 1, 2:
            canProceed = true
        default:
            canProceed = false
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 0) {
            ForEach(0..<3) { i in
                HStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(i <= currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 28, height: 28)
                        Text("\(i + 1)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(i <= currentStep ? .white : .secondary)
                    }
                    if i < 2 {
                        Rectangle()
                            .fill(i < currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 48)
    }

    private var navigationBar: some View {
        HStack {
            if currentStep > 0 {
                Button(String(localized: "onboarding.back", defaultValue: "Back")) {
                    withAnimation { currentStep -= 1 }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            Spacer()

            if currentStep < 2 {
                Button(String(localized: "onboarding.next", defaultValue: "Next")) {
                    withAnimation { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canProceed)
                .keyboardShortcut(.return, modifiers: [])
            } else {
                Button(String(localized: "onboarding.finish", defaultValue: "Get Started")) {
                    // The main window swaps to the dashboard when this flips.
                    settingsStore.hasCompletedOnboarding = true
                    appController.startHotkeyMonitoring()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }
}
