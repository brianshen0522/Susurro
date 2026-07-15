import AppKit
import Combine
import SwiftUI

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var audioLevel: Float = 0
}

@MainActor
final class OverlayController: ObservableObject {
    private var panel: OverlayPanel?
    private var hostingView: NSHostingView<OverlayLiveView>?
    private var cancellables = Set<AnyCancellable>()
    private var dismissTask: Task<Void, Never>?
    private let viewModel = OverlayViewModel()

    func setup(appController: AppController) {
        appController.$dictationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                self.viewModel.state = state
                self.handleStateChange(state)
            }
            .store(in: &cancellables)

        appController.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.viewModel.audioLevel = level
            }
            .store(in: &cancellables)
    }

    private func handleStateChange(_ state: DictationState) {
        switch state {
        case .idle:
            hidePanel()
        case .recording, .processing, .error:
            showPanel()
            if case .error = state {
                dismissTask?.cancel()
                dismissTask = Task {
                    try? await Task.sleep(for: .seconds(3))
                    await MainActor.run { self.hidePanel() }
                }
            } else {
                dismissTask?.cancel()
                dismissTask = nil
            }
        }
    }

    private func showPanel() {
        if panel == nil {
            let p = OverlayPanel()
            panel = p
            let view = OverlayLiveView(viewModel: viewModel)
            let hosting = NSHostingView(rootView: view)
            hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 76)
            p.contentView = hosting
            hostingView = hosting
        }
        panel?.show(on: NSScreen.main)
    }

    private func hidePanel() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.hide()
        panel = nil
        hostingView = nil
    }
}

struct OverlayLiveView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        OverlayView(state: viewModel.state, audioLevel: viewModel.audioLevel)
    }
}
