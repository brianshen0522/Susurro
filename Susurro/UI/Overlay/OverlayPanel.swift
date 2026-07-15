import AppKit
import SwiftUI

final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 76),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hasShadow = false
    }

    func show(on screen: NSScreen?) {
        let targetScreen = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }
        let screenFrame = screen.visibleFrame
        let w: CGFloat = 320
        let h: CGFloat = 76
        setFrame(NSRect(x: screenFrame.midX - w / 2, y: screenFrame.minY + 48, width: w, height: h), display: false)
        orderFrontRegardless()
    }

    func hide() { orderOut(nil) }
}

// MARK: - Waveform

struct OverlayWaveformView: View {
    let audioLevel: Float

    /// Each capsule gets its own gain so the pill moves organically instead
    /// of pulsing as one symmetric block. The pattern loosely echoes the
    /// app icon's whisper mark: an early swell that trails off.
    private static let barGains: [Float] = [0.45, 0.9, 0.6, 1.0, 0.72, 0.88, 0.55, 0.8, 0.42, 0.62, 0.3]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.barGains.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: barHeight(at: index))
                    .animation(.easeOut(duration: 0.1), value: audioLevel)
            }
        }
        .frame(height: 22)
    }

    private func barHeight(at index: Int) -> CGFloat {
        // Raw mic RMS for speech is small; a sub-linear curve keeps quiet
        // speech visible without letting loud input slam every bar to max.
        let level = min(pow(max(audioLevel, 0) * 4, 0.8), 1)
        return CGFloat(3 + 19 * level * Self.barGains[index])
    }
}

// MARK: - Spinner Ring

struct SpinnerRingView: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: 18, height: 18)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Overlay Content

struct OverlayView: View {
    let state: DictationState
    let audioLevel: Float

    var body: some View {
        ZStack {
            stateContent
                .padding(.horizontal, pillHPad)
                .padding(.vertical, pillVPad)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.72))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
                )
                .animation(.easeInOut(duration: 0.2), value: stateKey)
        }
        .frame(width: 320, height: 76, alignment: .center)
    }

    private var stateKey: String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .error: return "error"
        }
    }

    private var pillHPad: CGFloat {
        switch state {
        case .recording: return 16
        default: return 14
        }
    }

    private var pillVPad: CGFloat { 10 }

    @ViewBuilder
    private var stateContent: some View {
        switch state {
        case .idle:
            EmptyView()

        case .recording:
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 6, height: 6)

                OverlayWaveformView(audioLevel: audioLevel)
                    .frame(width: 80)

                Text("Listening")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

        case .processing:
            HStack(spacing: 10) {
                SpinnerRingView()
                Text("Processing…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

        case .error(let msg):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.red)
                Text(errorTitle(msg))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: 240, alignment: .leading)
        }
    }

    private func errorTitle(_ msg: String) -> String {
        let lower = msg.lowercased()
        if lower.contains("no model") || lower.contains("model loaded") { return "No model loaded" }
        if lower.contains("microphone") { return "Microphone unavailable" }
        if lower.contains("network") || lower.contains("http") { return "Network error" }
        return msg.count > 40 ? String(msg.prefix(37)) + "…" : msg
    }
}

// MARK: - Visual Effect

struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blendingMode
    }
}
