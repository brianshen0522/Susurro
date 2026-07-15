import Combine
import Foundation
import Sparkle
import SwiftUI

/// Wraps Sparkle's updater so SwiftUI views can bind to it. While Susurro is
/// in beta every release ships on the "beta" appcast channel; the toggle
/// lets users opt out once stable releases exist.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    private var updaterController: SPUStandardUpdaterController!

    @AppStorage("receiveBetaUpdates") var receiveBetaUpdates = true

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    var updater: SPUUpdater { updaterController.updater }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Reading UserDefaults directly keeps this nonisolated method off
        // the main actor; the key matches the @AppStorage above.
        let beta = UserDefaults.standard.object(forKey: "receiveBetaUpdates") as? Bool ?? true
        return beta ? ["beta"] : []
    }
}
