import AppKit
import Combine
import Foundation

/// Keeps the app's activation policy in sync with the "Hide Dock Icon"
/// setting: `.accessory` (no Dock icon, true background app) while the user
/// wants it hidden and no regular window is open, `.regular` otherwise.
/// Windows require the temporary switch back — an accessory app has no main
/// menu, so window key equivalents (⌘, ⌘W ⌘Q) would stop working while the
/// main window is in front.
@MainActor
final class DockIconController: ObservableObject {
    private var cancellables = Set<AnyCancellable>()

    init() {
        let center = NotificationCenter.default

        center.publisher(for: NSApplication.didFinishLaunchingNotification)
            .merge(with: center.publisher(for: NSWindow.didBecomeKeyNotification))
            .merge(with: center.publisher(for: UserDefaults.didChangeNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // A closing window is still visible when willClose fires; re-evaluate
        // on the next runloop turn, once it no longer counts.
        center.publisher(for: NSWindow.willCloseNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        let defaults = UserDefaults.standard
        let hideDock = defaults.bool(forKey: "hideDockIcon")
        // showInMenuBar defaults to true when the key was never written.
        let showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        let hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")

        // Never let both the Dock icon and the menu bar item be hidden — the
        // app would become unreachable. Whatever UI flipped the last switch,
        // force the menu bar item back on (the write retriggers refresh).
        if hideDock && !showInMenuBar {
            defaults.set(true, forKey: "showInMenuBar")
            return
        }

        // The overlay NSPanel and the status item's window can't become main,
        // so only real windows (main window, About) hold the app in .regular.
        let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let desired: NSApplication.ActivationPolicy =
            hideDock && hasCompletedOnboarding && !hasVisibleWindow ? .accessory : .regular

        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
        // Switching policy while a window is up can drop the app behind
        // others; bring it back to front.
        if desired == .regular && hasVisibleWindow {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
