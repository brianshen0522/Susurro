import Foundation
import SwiftUI

struct ModelDownloadProgressView: View {
    let progress: ModelDownloadProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .animation(.easeOut(duration: 0.2), value: progress.fractionCompleted)

            HStack(spacing: 8) {
                Text(percentText)
                    .fontWeight(.medium)
                Spacer(minLength: 8)
                Text(downloadedText)
            }

            HStack(spacing: 8) {
                Text(speedText)
                Spacer(minLength: 8)
                Text(remainingText)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var percentText: String {
        let fraction = progress.fractionCompleted.isFinite
            ? min(max(progress.fractionCompleted, 0), 1)
            : 0
        return "\(Int((fraction * 100).rounded(.down)))%"
    }

    private var downloadedText: String {
        let downloaded = Self.byteString(max(progress.downloadedBytes, 0))
        guard let totalBytes = progress.totalBytes else {
            return downloaded
        }
        let estimatePrefix = progress.isTotalEstimated ? "~" : ""
        return "\(downloaded) / \(estimatePrefix)\(Self.byteString(max(totalBytes, 0)))"
    }

    private var speedText: String {
        guard let bytesPerSecond = progress.bytesPerSecond,
              bytesPerSecond.isFinite,
              bytesPerSecond > 0
        else {
            return String(
                localized: "model.download.calculatingSpeed",
                defaultValue: "Calculating speed…"
            )
        }

        let maximumDisplaySpeed = 1_000_000_000_000_000.0
        let safeBytes = Int64(min(bytesPerSecond.rounded(), maximumDisplaySpeed))
        return "\(Self.byteString(safeBytes))/s"
    }

    private var remainingText: String {
        guard let remaining = progress.estimatedTimeRemaining,
              remaining.isFinite,
              remaining >= 0
        else {
            return String(
                localized: "model.download.estimating",
                defaultValue: "Estimating…"
            )
        }
        return "About \(Self.durationString(remaining)) left"
    }

    private static func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func durationString(_ interval: TimeInterval) -> String {
        let maximumDisplaySeconds = 31_536_000.0
        let totalSeconds = max(Int(min(interval.rounded(), maximumDisplaySeconds)), 1)
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        let totalMinutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if totalMinutes < 60 {
            return seconds > 0 ? "\(totalMinutes)m \(seconds)s" : "\(totalMinutes)m"
        }

        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
    }
}
