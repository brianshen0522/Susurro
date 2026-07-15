import Combine
import SwiftUI

enum MainPage: String, CaseIterable, Identifiable {
    case transcript
    case files
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript:
            return String(localized: "page.transcript", defaultValue: "Transcript")
        case .files:
            return String(localized: "page.files", defaultValue: "Files")
        case .settings:
            return String(localized: "page.settings", defaultValue: "Settings")
        }
    }

    var systemImage: String {
        switch self {
        case .transcript: return "text.quote"
        case .files: return "film"
        case .settings: return "gearshape"
        }
    }
}

/// Shared selection state for the main window sidebar, so the menu bar and
/// app commands can deep-link to a specific page.
@MainActor
final class NavigationModel: ObservableObject {
    @Published var selectedPage: MainPage = .transcript
}
