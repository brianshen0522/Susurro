import Combine
import Foundation
import WhisperKit

struct ModelDownloadProgress: Equatable, Sendable {
    let fractionCompleted: Double
    let downloadedBytes: Int64
    let totalBytes: Int64?
    let bytesPerSecond: Double?
    let estimatedTimeRemaining: TimeInterval?
    let isTotalEstimated: Bool
}

@MainActor
final class ModelManager: ObservableObject {
    @Published private(set) var availableModels: [WhisperModelSize]
    @Published var modelStatuses: [WhisperModelSize: ModelStatus]
    @Published var currentlyLoadedModel: WhisperModelSize?
    @Published var currentRAMUsageMB: Double = 0

    private var whisperKit: WhisperKit?
    private var ramUpdateTask: Task<Void, Never>?
    private var catalogRefreshTask: Task<Void, Never>?
    private var downloadTasks: [WhisperModelSize: Task<Void, Error>] = [:]
    private var downloadPreparationTasks: [WhisperModelSize: Task<Void, Never>] = [:]
    private var downloadAttemptIDs: [WhisperModelSize: UUID] = [:]
    private var downloadTrackingStates: [WhisperModelSize: DownloadTrackingState] = [:]
    private var finishingCancelledDownloads: [WhisperModelSize: CancelledDownload] = [:]

    enum ModelStatus: Equatable, Sendable {
        case notDownloaded
        case downloading(progress: ModelDownloadProgress)
        case loading
        case downloaded
        case loaded
    }

    private struct DownloadTrackingState {
        var frameworkFraction: Double
        var publishedFraction: Double
        var downloadedBytes: Int64
        var totalBytes: Int64?
        var isTotalEstimated: Bool
        var smoothedBytesPerSecond: Double?
    }

    private struct CancelledDownload {
        let id: UUID
        let task: Task<Void, Error>
    }

    private static let completionMarkerName = ".susurro-download-complete"

    static let modelsDirectory: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Susurro/Models", isDirectory: true)
    }()

    static func modelFolder(for model: WhisperModelSize) -> URL {
        modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(model.whisperKitName)
    }

    init() {
        let bundledSupport = WhisperKit.recommendedModels()
        let supportedModels = bundledSupport.supported
            .compactMap(WhisperModelSize.init(rawValue:))
            .filter(\.isMultilingual)
        let initialModels = WhisperModelSize.smallestVariants(
            WhisperModelSize.allCases + supportedModels + Self.downloadedModels()
        )
        availableModels = initialModels
        modelStatuses = Dictionary(uniqueKeysWithValues: initialModels.map { ($0, .notDownloaded) })

        refreshDownloadedStatus()
        startRAMMonitoring()
        catalogRefreshTask = Task { [weak self] in
            await Task.yield()
            await self?.refreshModelCatalog()
        }
    }

    deinit {
        ramUpdateTask?.cancel()
        catalogRefreshTask?.cancel()
        for task in downloadTasks.values {
            task.cancel()
        }
        for task in downloadPreparationTasks.values {
            task.cancel()
        }
        for download in finishingCancelledDownloads.values {
            download.task.cancel()
        }
    }

    func refreshDownloadedStatus() {
        for size in availableModels {
            switch modelStatuses[size] {
            case .loaded, .loading, .downloading:
                break
            default:
                modelStatuses[size] = diskStatus(for: size)
            }
        }
    }

    func download(_ model: WhisperModelSize) async throws {
        if let cancelledDownload = finishingCancelledDownloads[model] {
            _ = await cancelledDownload.task.result
            if finishingCancelledDownloads[model]?.id == cancelledDownload.id {
                finishingCancelledDownloads[model] = nil
            }
        }

        guard modelStatuses[model] ?? .notDownloaded == .notDownloaded else { return }

        try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)

        let attemptID = UUID()
        let modelFolder = Self.modelFolder(for: model)
        let incompleteFolder = Self.incompleteDownloadFolder(for: model)
        let fallbackTotalBytes = max(Int64(model.approxDiskSizeMB) * 1_000_000, 1)

        downloadAttemptIDs[model] = attemptID
        downloadTrackingStates[model] = DownloadTrackingState(
            frameworkFraction: 0,
            publishedFraction: 0,
            downloadedBytes: 0,
            totalBytes: fallbackTotalBytes,
            isTotalEstimated: true,
            smoothedBytesPerSecond: nil
        )
        publishDownloadProgress(for: model)

        let preparationTask = Task { [weak self] in
            let existingBytes = await Task.detached(priority: .utility) {
                ModelDownloadFiles.downloadedBytes(
                    modelFolder: modelFolder,
                    incompleteFolder: incompleteFolder
                )
            }.value
            guard !Task.isCancelled else { return }
            self?.recordDownloadedBytes(
                existingBytes,
                frameworkFraction: 0,
                rawBytesPerSecond: nil,
                for: model,
                attemptID: attemptID
            )

            let exactTotalBytes = await ModelDownloadRemoteMetadata.totalBytes(for: model.whisperKitName)
            guard !Task.isCancelled, let exactTotalBytes else { return }
            self?.recordExactTotalBytes(exactTotalBytes, for: model, attemptID: attemptID)
        }
        downloadPreparationTasks[model] = preparationTask

        let task = Task<Void, Error> {
            _ = try await WhisperKit.download(
                variant: model.whisperKitName,
                downloadBase: Self.modelsDirectory,
                useBackgroundSession: false,
                progressCallback: { progress in
                    let frameworkFraction = progress.fractionCompleted
                    let rawBytesPerSecond = (progress.userInfo[.throughputKey] as? NSNumber)?.doubleValue

                    Task { @MainActor in
                        let downloadedBytes = await Task.detached(priority: .utility) {
                            ModelDownloadFiles.downloadedBytes(
                                modelFolder: modelFolder,
                                incompleteFolder: incompleteFolder
                            )
                        }.value
                        self.recordDownloadedBytes(
                            downloadedBytes,
                            frameworkFraction: frameworkFraction,
                            rawBytesPerSecond: rawBytesPerSecond,
                            for: model,
                            attemptID: attemptID
                        )
                    }
                }
            )
            try Task.checkCancellation()
            try ModelDownloadFiles.writeCompletionMarker(
                in: modelFolder,
                named: Self.completionMarkerName
            )
        }

        downloadTasks[model] = task

        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            let isCurrentAttempt = downloadAttemptIDs[model] == attemptID
            if isCurrentAttempt {
                clearDownloadAttempt(for: model)
                modelStatuses[model] = .notDownloaded
            }

            if !isCurrentAttempt || Task.isCancelled || Self.isCancellation(error) {
                throw CancellationError()
            }
            throw error
        }

        guard downloadAttemptIDs[model] == attemptID else {
            throw CancellationError()
        }
        clearDownloadAttempt(for: model)
        modelStatuses[model] = .downloaded
    }

    func cancelDownload(_ model: WhisperModelSize) {
        downloadAttemptIDs[model] = nil
        if let task = downloadTasks[model] {
            let cancellationID = UUID()
            task.cancel()
            finishingCancelledDownloads[model] = CancelledDownload(
                id: cancellationID,
                task: task
            )
            Task { [weak self] in
                _ = await task.result
                guard self?.finishingCancelledDownloads[model]?.id == cancellationID else {
                    return
                }
                self?.finishingCancelledDownloads[model] = nil
            }
        }
        downloadPreparationTasks[model]?.cancel()
        downloadTasks[model] = nil
        downloadPreparationTasks[model] = nil
        downloadTrackingStates[model] = nil
        modelStatuses[model] = .notDownloaded
    }

    func load(_ model: WhisperModelSize) async throws {
        if currentlyLoadedModel != nil {
            await unloadCurrentModel()
        }

        modelStatuses[model] = .loading

        do {
            let folder = Self.modelFolder(for: model)
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                load: true,
                download: false
            )

            let kit = try await WhisperKit(config)
            whisperKit = kit
            currentlyLoadedModel = model
            modelStatuses[model] = .loaded
        } catch {
            modelStatuses[model] = .downloaded
            throw error
        }
    }

    func unloadCurrentModel() async {
        guard let loaded = currentlyLoadedModel else { return }
        whisperKit = nil
        currentlyLoadedModel = nil
        modelStatuses[loaded] = diskStatus(for: loaded)
        currentRAMUsageMB = 0
    }

    private func diskStatus(for model: WhisperModelSize) -> ModelStatus {
        let hasIncompleteFiles = ModelDownloadFiles.hasIncompleteFiles(
            in: Self.incompleteDownloadFolder(for: model)
        )
        return !hasIncompleteFiles && Self.isCompleteModelFolder(Self.modelFolder(for: model))
            ? .downloaded
            : .notDownloaded
    }

    private static func incompleteDownloadFolder(for model: WhisperModelSize) -> URL {
        modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/.cache/huggingface/download", isDirectory: true)
            .appendingPathComponent(model.whisperKitName, isDirectory: true)
    }

    private static func isCompleteModelFolder(_ folder: URL) -> Bool {
        let fileManager = FileManager.default
        let marker = folder.appendingPathComponent(completionMarkerName)
        if fileManager.fileExists(atPath: marker.path) {
            return true
        }

        let requiredRelativePaths = [
            "config.json",
            "generation_config.json",
            "AudioEncoder.mlmodelc/coremldata.bin",
            "AudioEncoder.mlmodelc/weights/weight.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/weights/weight.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/weights/weight.bin",
        ]
        return requiredRelativePaths.allSatisfy {
            fileManager.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    private func recordDownloadedBytes(
        _ downloadedBytes: Int64,
        frameworkFraction: Double,
        rawBytesPerSecond: Double?,
        for model: WhisperModelSize,
        attemptID: UUID
    ) {
        guard downloadAttemptIDs[model] == attemptID,
              var state = downloadTrackingStates[model],
              case .downloading = modelStatuses[model]
        else {
            return
        }

        let safeFrameworkFraction = frameworkFraction.isFinite
            ? min(max(frameworkFraction, 0), 1)
            : 0
        let isCurrentOrNewerSample = safeFrameworkFraction >= state.frameworkFraction
        state.frameworkFraction = max(state.frameworkFraction, safeFrameworkFraction)
        state.downloadedBytes = max(state.downloadedBytes, max(downloadedBytes, 0))

        if let rawBytesPerSecond,
           rawBytesPerSecond.isFinite,
           rawBytesPerSecond > 0,
           isCurrentOrNewerSample
        {
            if let previousSpeed = state.smoothedBytesPerSecond {
                state.smoothedBytesPerSecond = previousSpeed * 0.75 + rawBytesPerSecond * 0.25
            } else {
                state.smoothedBytesPerSecond = rawBytesPerSecond
            }
        }

        downloadTrackingStates[model] = state
        publishDownloadProgress(for: model)
    }

    private func recordExactTotalBytes(
        _ totalBytes: Int64,
        for model: WhisperModelSize,
        attemptID: UUID
    ) {
        guard totalBytes > 0,
              downloadAttemptIDs[model] == attemptID,
              var state = downloadTrackingStates[model],
              case .downloading = modelStatuses[model]
        else {
            return
        }

        state.totalBytes = totalBytes
        state.isTotalEstimated = false
        downloadTrackingStates[model] = state
        publishDownloadProgress(for: model)
    }

    private func publishDownloadProgress(for model: WhisperModelSize) {
        guard var state = downloadTrackingStates[model] else { return }

        let byteFraction: Double?
        if let totalBytes = state.totalBytes, totalBytes > 0, state.downloadedBytes <= totalBytes {
            byteFraction = Double(state.downloadedBytes) / Double(totalBytes)
        } else {
            byteFraction = nil
        }

        let candidateFraction = byteFraction ?? state.frameworkFraction
        state.publishedFraction = max(
            state.publishedFraction,
            min(max(candidateFraction, 0), 0.99)
        )

        let remainingSeconds: TimeInterval?
        if let totalBytes = state.totalBytes,
           totalBytes > state.downloadedBytes,
           let speed = state.smoothedBytesPerSecond,
           speed.isFinite,
           speed > 1
        {
            let estimate = Double(totalBytes - state.downloadedBytes) / speed
            remainingSeconds = estimate.isFinite && estimate >= 0 ? estimate : nil
        } else {
            remainingSeconds = nil
        }

        downloadTrackingStates[model] = state
        modelStatuses[model] = .downloading(
            progress: ModelDownloadProgress(
                fractionCompleted: state.publishedFraction,
                downloadedBytes: state.downloadedBytes,
                totalBytes: state.totalBytes,
                bytesPerSecond: state.smoothedBytesPerSecond,
                estimatedTimeRemaining: remainingSeconds,
                isTotalEstimated: state.isTotalEstimated
            )
        )
    }

    private func clearDownloadAttempt(for model: WhisperModelSize) {
        downloadTasks[model] = nil
        downloadPreparationTasks[model]?.cancel()
        downloadPreparationTasks[model] = nil
        downloadAttemptIDs[model] = nil
        downloadTrackingStates[model] = nil
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }

    private func refreshModelCatalog() async {
        let remoteSupport = await WhisperKit.recommendedRemoteModels(
            downloadBase: Self.modelsDirectory
        )
        guard !Task.isCancelled else { return }

        let supportedModels = remoteSupport.supported
            .compactMap(WhisperModelSize.init(rawValue:))
            .filter(\.isMultilingual)
        let mergedModels = WhisperModelSize.smallestVariants(
            WhisperModelSize.allCases + supportedModels + Self.downloadedModels()
        )

        for model in mergedModels where modelStatuses[model] == nil {
            modelStatuses[model] = diskStatus(for: model)
        }
        if availableModels != mergedModels {
            availableModels = mergedModels
        }
    }

    private static func downloadedModels() -> [WhisperModelSize] {
        let repositoryFolder = modelsDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: repositoryFolder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return folders.compactMap { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return WhisperModelSize(rawValue: folder.lastPathComponent)
        }.filter(\.isMultilingual)
    }

    func delete(_ model: WhisperModelSize) throws {
        if currentlyLoadedModel == model {
            whisperKit = nil
            currentlyLoadedModel = nil
        }
        let url = Self.modelFolder(for: model)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        modelStatuses[model] = .notDownloaded
    }

    func getWhisperKit() -> WhisperKit? {
        whisperKit
    }

    func testTranscription(sampleAudio: URL) async throws -> String {
        guard let kit = whisperKit else {
            throw ModelManagerError.noModelLoaded
        }
        let results = try await kit.transcribe(
            audioPath: sampleAudio.path,
            decodeOptions: WhisperTranscriptionOptions.multilingual
        )
        return results.map { $0.text }.joined(separator: " ")
    }

    private func startRAMMonitoring() {
        ramUpdateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updateRAMUsage()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func updateRAMUsage() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            currentRAMUsageMB = Double(info.resident_size) / 1_048_576
        }
    }
}

enum ModelManagerError: LocalizedError {
    case noModelLoaded
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noModelLoaded:
            return String(localized: "error.noModelLoaded", defaultValue: "No model is loaded. Please load a model first.")
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        }
    }
}

private enum ModelDownloadFiles {
    nonisolated static func downloadedBytes(modelFolder: URL, incompleteFolder: URL) -> Int64 {
        var bytesByRelativePath = regularFileSizes(in: modelFolder)

        for (incompletePath, incompleteBytes) in regularFileSizes(in: incompleteFolder) {
            guard let destinationPath = destinationPath(forIncompletePath: incompletePath) else {
                continue
            }
            bytesByRelativePath[destinationPath] = max(
                bytesByRelativePath[destinationPath] ?? 0,
                incompleteBytes
            )
        }

        return bytesByRelativePath.values.reduce(into: Int64(0)) { total, fileBytes in
            let (sum, overflow) = total.addingReportingOverflow(fileBytes)
            total = overflow ? Int64.max : sum
        }
    }

    nonisolated static func hasIncompleteFiles(in folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent.hasSuffix(".incomplete") {
            if (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                return true
            }
        }
        return false
    }

    nonisolated static func writeCompletionMarker(in folder: URL, named markerName: String) throws {
        let markerURL = folder.appendingPathComponent(markerName)
        try Data().write(to: markerURL, options: .atomic)
    }

    private nonisolated static func regularFileSizes(in folder: URL) -> [String: Int64] {
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return [:]
        }

        let basePath = folder.standardizedFileURL.path + "/"
        var result: [String: Int64] = [:]
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0
            else {
                continue
            }

            let standardizedPath = fileURL.standardizedFileURL.path
            guard standardizedPath.hasPrefix(basePath) else { continue }
            let relativePath = String(standardizedPath.dropFirst(basePath.count))
            result[relativePath] = Int64(fileSize)
        }
        return result
    }

    private nonisolated static func destinationPath(forIncompletePath path: String) -> String? {
        let incompleteSuffix = ".incomplete"
        guard path.hasSuffix(incompleteSuffix) else { return nil }

        let withoutIncomplete = path.dropLast(incompleteSuffix.count)
        guard let etagSeparator = withoutIncomplete.lastIndex(of: ".") else { return nil }
        return String(withoutIncomplete[..<etagSeparator])
    }
}

private enum ModelDownloadRemoteMetadata {
    private struct HubTreeEntry: Decodable, Sendable {
        let type: String
        let size: Int64?
        let path: String
    }

    nonisolated static func totalBytes(for modelID: String) async -> Int64? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/api/models/argmaxinc/whisperkit-coreml/tree/main/\(modelID)"
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "expand", value: "false"),
            URLQueryItem(name: "limit", value: "1000"),
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode)
            else {
                return nil
            }

            let entries = try JSONDecoder().decode([HubTreeEntry].self, from: data)
            let files = entries.filter {
                $0.type == "file" && $0.path.hasPrefix(modelID + "/")
            }
            guard !files.isEmpty, files.allSatisfy({ $0.size != nil }) else {
                return nil
            }

            var total: Int64 = 0
            for file in files {
                guard let size = file.size, size >= 0 else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(size)
                guard !overflow else { return nil }
                total = sum
            }
            return total > 0 ? total : nil
        } catch {
            return nil
        }
    }
}
