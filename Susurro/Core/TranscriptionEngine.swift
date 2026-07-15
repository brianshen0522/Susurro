import AVFoundation
import Foundation
import WhisperKit

enum WhisperTranscriptionOptions {
    /// Preserve the language spoken in the audio. WhisperKit must detect the
    /// dominant language before prefilling the `.transcribe` prompt; otherwise
    /// a nil language falls back to English.
    static let multilingual = DecodingOptions(
        task: .transcribe,
        language: nil,
        usePrefillPrompt: true,
        detectLanguage: true
    )
}

protocol TranscriptionEngine: AnyObject {
    func transcribe(audio: AVAudioPCMBuffer) async throws -> String
}

final class WhisperKitEngine: TranscriptionEngine {
    private let modelManager: ModelManager

    init(modelManager: ModelManager) {
        self.modelManager = modelManager
    }

    func transcribe(audio: AVAudioPCMBuffer) async throws -> String {
        guard let kit = modelManager.getWhisperKit() else {
            throw TranscriptionError.noModelLoaded
        }

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try writeBufferToWAV(buffer: audio, url: tmpURL)

        let results = try await kit.transcribe(
            audioPath: tmpURL.path,
            decodeOptions: WhisperTranscriptionOptions.multilingual
        )
        return results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private func writeBufferToWAV(buffer: AVAudioPCMBuffer, url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }
}

final class OpenAIWhisperEngine: TranscriptionEngine {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func transcribe(audio: AVAudioPCMBuffer) async throws -> String {
        let settingsStore = self.settingsStore
        let apiKey = await MainActor.run {
            settingsStore.loadOpenAIKey()
        }
        guard let apiKey, !apiKey.isEmpty else {
            throw TranscriptionError.noAPIKey
        }

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try writeBufferToWAV(buffer: audio, url: tmpURL)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: tmpURL)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
        body.append("whisper-1\r\n".data(using: .utf8)!)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.networkError("HTTP \(httpResponse.statusCode): \(msg)")
        }

        let decoded = try JSONDecoder().decode(OpenAITranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespaces)
    }

    private func writeBufferToWAV(buffer: AVAudioPCMBuffer, url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings)
        try file.write(from: buffer)
    }
}

private struct OpenAITranscriptionResponse: Decodable {
    let text: String
}

enum TranscriptionError: LocalizedError {
    case noModelLoaded
    case noAPIKey
    case networkError(String)
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return String(localized: "error.noModelLoaded", defaultValue: "No model loaded. Please load a model from the Dashboard.")
        case .noAPIKey:
            return String(localized: "error.noAPIKey", defaultValue: "OpenAI API key is not set. Please configure it in Settings.")
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .transcriptionFailed(let msg):
            return "Transcription failed: \(msg)"
        }
    }
}
