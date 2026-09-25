import Foundation
import os

/// Connects the scan pipeline to `AppState`: starts and cancels scans, samples progress at a fixed rate,
/// publishes results, and persists them in the background.
@MainActor
final class ScanCoordinator {
    nonisolated private static let logger = Logger(subsystem: "SpaceLens", category: "ScanCoordinator")
    private static let progressSamplingInterval = Duration.milliseconds(100)

    private let appState: AppState
    private let engine: ScanEngine
    private var scanTask: Task<Void, Never>?

    init(appState: AppState, engine: ScanEngine = ScanEngine()) {
        self.appState = appState
        self.engine = engine
        appState.history = engine.loadHistory()
    }

    func startScan(path: String, options: ScanOptions, mode: ScanMode = .automatic) {
        cancelRunningScan()

        let progress = ScanProgress(estimatedTotalBytes: ScanScope.estimatedUsedBytes(forVolumeRoot: path))
        appState.scanStarted(progress: progress.snapshot())

        let engine = engine
        scanTask = Task { [weak appState] in
            let poller = Task { @MainActor [weak appState] in
                while !Task.isCancelled {
                    appState?.scanProgress = progress.snapshot()
                    try? await Task.sleep(for: Self.progressSamplingInterval)
                }
            }
            defer { poller.cancel() }

            // Detached so decoding, walking and sorting never run on the main actor.
            let work = Task.detached(priority: .userInitiated) {
                try await engine.run(rootPath: path, options: options, mode: mode, progress: progress)
            }

            do {
                let result = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                    poller.cancel()
                }
                guard !Task.isCancelled, let appState else { return }
                poller.cancel()
                appState.scanFinished(root: result.root, report: result.report)
                persist(result)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                appState?.scanFailed(message: error.localizedDescription)
            }
        }
    }

    /// Rescans the current results' root with its original options.
    func rescan(mode: ScanMode) {
        guard let report = appState.results?.report else { return }
        startScan(path: report.rootPath, options: report.options, mode: mode)
    }

    /// Stops the running scan and returns to the previous results, if any.
    func cancel() {
        cancelRunningScan()
        if appState.isScanning { appState.scanCancelled() }
    }

    private func cancelRunningScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    func clearHistory() {
        let engine = engine
        Task.detached(priority: .utility) { [weak appState] in
            do {
                try engine.clearHistoryAndCache()
            } catch {
                Self.logger.error("Failed to clear history: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { appState?.history = [] }
        }
    }

    private func persist(_ result: ScanResult) {
        let engine = engine
        Task.detached(priority: .utility) { [weak appState] in
            do {
                let history = try engine.persist(result)
                await MainActor.run { appState?.history = history }
            } catch {
                Self.logger.error("Failed to record scan: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
