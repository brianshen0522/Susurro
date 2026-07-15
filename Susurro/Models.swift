import Foundation

struct WhisperModelSize: RawRepresentable, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    var id: String { rawValue }
    var whisperKitName: String { rawValue }

    init?(rawValue: String) {
        let canonicalID = Self.legacyModelIDs[rawValue] ?? rawValue
        guard Self.isWhisperKitModelID(canonicalID) else { return nil }
        self.rawValue = canonicalID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let model = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid WhisperKit model identifier: \(rawValue)"
            )
        }
        self = model
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Every multilingual model currently published in Argmax's default
    /// whisperkit-coreml repository. The model manager reduces this catalog
    /// to the smallest download in each family before presenting it.
    static let allCases: [WhisperModelSize] = [
        // Multilingual models
        model("openai_whisper-tiny"),
        model("openai_whisper-base"),
        model("openai_whisper-small"),
        model("openai_whisper-small_216MB"),
        model("openai_whisper-medium"),
        model("openai_whisper-large-v2"),
        model("openai_whisper-large-v2_949MB"),
        model("openai_whisper-large-v2_turbo"),
        model("openai_whisper-large-v2_turbo_955MB"),
        model("openai_whisper-large-v3"),
        model("openai_whisper-large-v3_947MB"),
        model("openai_whisper-large-v3_turbo"),
        model("openai_whisper-large-v3_turbo_954MB"),
        model("openai_whisper-large-v3-v20240930"),
        model("openai_whisper-large-v3-v20240930_547MB"),
        model("openai_whisper-large-v3-v20240930_626MB"),
        model("openai_whisper-large-v3-v20240930_turbo"),
        model("openai_whisper-large-v3-v20240930_turbo_632MB"),
    ]

    // Keep source compatibility and migrate UserDefaults values written by
    // earlier Susurro versions.
    static let tiny = model("openai_whisper-tiny")
    static let small = model("openai_whisper-small")
    static let medium = model("openai_whisper-medium")
    static let largeV2 = model("openai_whisper-large-v2")

    private static let legacyModelIDs = [
        "tiny": "openai_whisper-tiny",
        "small": "openai_whisper-small",
        "medium": "openai_whisper-medium",
        "largeV2": "openai_whisper-large-v2",
    ]

    private static func model(_ id: String) -> WhisperModelSize {
        guard let model = WhisperModelSize(rawValue: id) else {
            preconditionFailure("Invalid built-in WhisperKit model identifier: \(id)")
        }
        return model
    }

    private static func isWhisperKitModelID(_ id: String) -> Bool {
        id.hasPrefix("openai_whisper-") || id.hasPrefix("distil-whisper_")
    }

    static func orderedUnique(_ models: [WhisperModelSize]) -> [WhisperModelSize] {
        let builtInOrder = Dictionary(
            uniqueKeysWithValues: allCases.enumerated().map { ($0.element.rawValue, $0.offset) }
        )
        var seen = Set<String>()
        return models
            .filter { seen.insert($0.rawValue).inserted }
            .sorted { lhs, rhs in
                let lhsIndex = builtInOrder[lhs.rawValue] ?? Int.max
                let rhsIndex = builtInOrder[rhs.rawValue] ?? Int.max
                if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    /// Collapses full, compressed, turbo, and dated revisions of the same
    /// base model version into one user-facing choice. Susurro deliberately
    /// chooses the smallest published download so users do not need to
    /// understand WhisperKit's packaging variants.
    static func smallestVariants(_ models: [WhisperModelSize]) -> [WhisperModelSize] {
        var smallestByFamily: [String: WhisperModelSize] = [:]

        for model in models where model.isMultilingual {
            let familyID = model.selectionFamilyID
            guard let current = smallestByFamily[familyID] else {
                smallestByFamily[familyID] = model
                continue
            }

            if model.approxDiskSizeMB < current.approxDiskSizeMB {
                smallestByFamily[familyID] = model
            }
        }

        return orderedUnique(Array(smallestByFamily.values))
    }

    var isEnglishOnly: Bool {
        rawValue.contains(".en") || rawValue.hasPrefix("distil-whisper_")
    }

    var isMultilingual: Bool { !isEnglishOnly }

    var displayName: String {
        var identifier = rawValue
        let isDistilled = identifier.hasPrefix("distil-whisper_")
        identifier = identifier
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_distil-", with: "")

        if let sizeRange = identifier.range(
            of: #"_[0-9]+MB$"#,
            options: .regularExpression
        ) {
            identifier.removeSubrange(sizeRange)
        }

        let isTurbo = identifier.hasSuffix("_turbo")
        identifier = identifier.replacingOccurrences(of: "_turbo", with: "")
        identifier = identifier.replacingOccurrences(of: ".en", with: "")

        let familyName: String
        switch identifier {
        case "tiny": familyName = "Tiny"
        case "base": familyName = "Base"
        case "small": familyName = "Small"
        case "medium": familyName = "Medium"
        case "large-v2": familyName = "Large v2"
        case "large-v3": familyName = "Large v3"
        case "large-v3-v20240930": familyName = "Large v3 (2024-09-30)"
        default:
            familyName = identifier.replacingOccurrences(of: "-", with: " ").capitalized
        }

        return [
            isDistilled ? "Distil \(familyName)" : familyName,
            isTurbo ? "Turbo" : nil,
            compressedSizeMB.map { "(\($0) MB)" },
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var compressedSizeMB: Int? {
        guard let range = rawValue.range(of: #"[0-9]+(?=MB$)"#, options: .regularExpression) else {
            return nil
        }
        return Int(rawValue[range])
    }

    private var selectionFamilyID: String {
        var identifier = rawValue
            .replacingOccurrences(of: "openai_whisper-", with: "")
            .replacingOccurrences(of: "distil-whisper_distil-", with: "")

        if let sizeRange = identifier.range(
            of: #"_[0-9]+MB$"#,
            options: .regularExpression
        ) {
            identifier.removeSubrange(sizeRange)
        }
        if identifier.hasSuffix("_turbo") {
            identifier.removeLast("_turbo".count)
        }
        if let datedRevisionRange = identifier.range(
            of: #"-v[0-9]{8}$"#,
            options: .regularExpression
        ) {
            identifier.removeSubrange(datedRevisionRange)
        }
        return identifier.replacingOccurrences(of: ".en", with: "")
    }

    var approxDiskSizeMB: Int {
        if let compressedSizeMB { return compressedSizeMB }
        if rawValue.contains("tiny") { return 75 }
        if rawValue.contains("base") { return 145 }
        if rawValue.contains("small") { return 480 }
        if rawValue.contains("medium") { return 1_500 }
        if rawValue.hasPrefix("distil-whisper_") { return 1_500 }
        return 3_000
    }

    var approxRAMUsageMB: Int {
        if rawValue.contains("tiny") { return 250 }
        if rawValue.contains("base") { return 450 }
        if rawValue.contains("small") { return 900 }
        if rawValue.contains("medium") { return 2_200 }
        if rawValue.hasPrefix("distil-whisper_") { return 2_400 }
        return 3_800
    }
}

enum TranscriptionSource: String, Codable {
    case local
    case openAIAPI

    var localModel: WhisperModelSize? {
        get { nil }
    }
}

enum HotkeyTriggerMode: Codable, Equatable {
    case pressAndHold(key: HotkeyKey)

    var key: HotkeyKey {
        switch self {
        case .pressAndHold(let key): return key
        }
    }
}

enum HotkeyKey: String, Codable, CaseIterable, Identifiable {
    case fn
    case rightCommand
    case rightOption
    case f13

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fn: return "Fn"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .f13: return "F13"
        }
    }
}

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .light: return String(localized: "theme.light", defaultValue: "Light")
        case .dark: return String(localized: "theme.dark", defaultValue: "Dark")
        case .system: return String(localized: "theme.system", defaultValue: "System")
        }
    }
}

enum TextInsertionMode: String, Codable, CaseIterable, Identifiable {
    case simulateTyping
    case pasteboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simulateTyping: return String(localized: "insertion.simulateTyping", defaultValue: "Simulate Typing")
        case .pasteboard: return String(localized: "insertion.pasteboard", defaultValue: "Clipboard Paste")
        }
    }
}
