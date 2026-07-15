import AVFoundation
import Combine

final class AudioEngine: ObservableObject {
    private var engine: AVAudioEngine?
    private var buffers: [AVAudioPCMBuffer] = []
    private var inputFormat: AVAudioFormat?
    private let audioLevelSubject = PassthroughSubject<Float, Never>()

    var audioLevelPublisher: AnyPublisher<Float, Never> {
        audioLevelSubject.eraseToAnyPublisher()
    }

    enum AudioEngineError: LocalizedError {
        case microphoneUnavailable
        case formatUnsupported
        case recordingNotActive

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return String(localized: "error.micUnavailable", defaultValue: "Microphone is unavailable.")
            case .formatUnsupported:
                return String(localized: "error.formatUnsupported", defaultValue: "Audio format is not supported.")
            case .recordingNotActive:
                return String(localized: "error.recordingNotActive", defaultValue: "Recording is not active.")
            }
        }
    }

    func startRecording() throws {
        let newEngine = AVAudioEngine()
        engine = newEngine

        let inputNode = newEngine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0 else {
            throw AudioEngineError.microphoneUnavailable
        }

        let whisperFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )

        guard let targetFormat = whisperFormat else {
            throw AudioEngineError.formatUnsupported
        }

        buffers = []
        inputFormat = targetFormat

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let rms = self.calculateRMS(buffer: buffer)
            self.audioLevelSubject.send(rms)

            if let converted = self.convert(buffer: buffer, from: hardwareFormat, to: targetFormat) {
                self.buffers.append(converted)
            }
        }

        try newEngine.start()
    }

    func stopRecording() -> AVAudioPCMBuffer? {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        return merge(buffers: buffers, format: inputFormat)
    }

    func discardRecording() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        buffers = []
    }

    private func calculateRMS(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frames = Int(buffer.frameLength)
        let channel = channelData[0]
        var sum: Float = 0
        for i in 0..<frames {
            sum += channel[i] * channel[i]
        }
        return frames > 0 ? sqrt(sum / Float(frames)) : 0
    }

    private func convert(buffer: AVAudioPCMBuffer, from inputFmt: AVAudioFormat, to outputFmt: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: inputFmt, to: outputFmt) else { return nil }

        let ratio = outputFmt.sampleRate / inputFmt.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFmt, frameCapacity: outputFrameCapacity) else { return nil }

        var error: NSError?
        var inputConsumed = false

        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            inputConsumed = true
            return buffer
        }

        if error != nil { return nil }
        return outputBuffer
    }

    private func merge(buffers: [AVAudioPCMBuffer], format: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard let format, !buffers.isEmpty else { return nil }

        let totalFrames = buffers.reduce(0) { $0 + $1.frameLength }
        guard let merged = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return nil }

        merged.frameLength = totalFrames

        var offset: AVAudioFrameCount = 0
        for buf in buffers {
            let frames = buf.frameLength
            guard frames > 0, let srcData = buf.floatChannelData, let dstData = merged.floatChannelData else { continue }
            for ch in 0..<Int(format.channelCount) {
                dstData[ch].advanced(by: Int(offset)).initialize(from: srcData[ch], count: Int(frames))
            }
            offset += frames
        }

        return merged
    }
}
