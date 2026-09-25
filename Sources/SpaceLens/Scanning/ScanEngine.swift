import Foundation
import os

struct ScanResult: Sendable {
    var root: FileNode
    var report: ScanReport
    /// FSEvents position captured before the tree was read; stored with the snapshot.
    var checkpoint: ChangeJournal.Checkpoint?
}

/// UI-independent scan pipeline: chooses between an incremental update of the cached snapshot and a
/// full walk, runs it, and persists results.
struct ScanEngine: Sendable {
    private static let logger = Logger(subsystem: "SpaceLens", category: "ScanEngine")

    var snapshotStore = ScanSnapshotStore()
    var historyStore = ScanHistoryStore()
    var firmlinks: [Firmlink] = Firmlink.systemFirmlinks()

    /// Runs a scan. Heavy work (walking, decoding, sorting) happens on the caller's executor, so call
    /// this from a background task. Throws `CancellationError` when cancelled.
    func run(rootPath requestedPath: String, options: ScanOptions, mode: ScanMode, progress: ScanProgress) async throws -> ScanResult {
        let rootPath = ScanScope.canonicalPath(requestedPath)
        let scope = ScanScope(rootPath: rootPath, options: options, firmlinks: firmlinks)

        return try await DatalessMaterializationPolicy.withMaterializationDisabled {
            if mode == .automatic,
               let result = try await runIncremental(scope: scope, progress: progress) {
                return result
            }
            return try await runFull(scope: scope, progress: progress)
        }
    }

    /// Saves the snapshot (enabling incremental rescans) and appends to history. Returns the new history.
    func persist(_ result: ScanResult) throws -> [ScanHistoryEntry] {
        let metadata = ScanSnapshot.Metadata(
            rootPath: result.report.rootPath,
            options: result.report.options,
            checkpoint: result.checkpoint,
            report: result.report
        )
        do {
            try snapshotStore.save(ScanSnapshot(metadata: metadata, root: result.root))
        } catch {
            // A missing cache only costs speed on the next scan; history is still worth recording.
            Self.logger.error("Failed to save snapshot: \(error.localizedDescription, privacy: .public)")
        }
        return try historyStore.append(ScanHistoryEntry(completedAt: Date(), report: result.report))
    }

    func loadHistory() -> [ScanHistoryEntry] {
        do {
            return try historyStore.load()
        } catch {
            Self.logger.error("Failed to load history: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func clearHistoryAndCache() throws {
        try historyStore.removeAll()
        try snapshotStore.removeAll()
    }

    // MARK: - Pipelines

    private func runFull(scope: ScanScope, progress: ScanProgress) async throws -> ScanResult {
        progress.setPhase(.preparing)
        let checkpoint = ChangeJournal.checkpoint(forPath: scope.rootPath)
        let context = ScanContext(scope: scope, progress: progress)
        let root = try await FileScanner(context: context).scanRoot()
        try Task.checkCancellation()
        return ScanResult(
            root: root,
            report: makeReport(root: root, scope: scope, kind: .full, context: context, progress: progress),
            checkpoint: checkpoint
        )
    }

    /// Returns nil whenever the cached snapshot cannot be brought up to date reliably.
    private func runIncremental(scope: ScanScope, progress: ScanProgress) async throws -> ScanResult? {
        progress.setPhase(.loadingCache)
        let snapshot: ScanSnapshot
        do {
            guard let loaded = try snapshotStore.load(rootPath: scope.rootPath, options: scope.options) else {
                return nil
            }
            snapshot = loaded
        } catch {
            Self.logger.error("Discarding unreadable snapshot: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let previousCheckpoint = snapshot.metadata.checkpoint else { return nil }
        try Task.checkCancellation()

        // Capture the new position before replaying, so changes made during this scan are replayed next time.
        let checkpoint = ChangeJournal.checkpoint(forPath: scope.rootPath)
        guard var changes = await ChangeJournal.changes(
            since: previousCheckpoint,
            under: scope.rootPath,
            firmlinks: firmlinks
        ) else { return nil }
        try Task.checkCancellation()

        // Retry directories that were unreadable last time, e.g. after Full Disk Access was granted.
        changes.directories.formUnion(snapshot.metadata.report.inaccessiblePaths)

        let context = ScanContext(scope: scope, progress: progress)
        let scanner = IncrementalScanner(scanner: FileScanner(context: context))
        guard let root = try await scanner.apply(changes, to: snapshot.root) else { return nil }
        try Task.checkCancellation()

        var report = makeReport(
            root: root,
            scope: scope,
            kind: .incremental(changedDirectories: changes.count),
            context: context,
            progress: progress
        )
        // Recorded paths were retried above and re-recorded if still unreadable. Issues beyond the
        // recording cap could not be retried, so they still apply.
        let previousReport = snapshot.metadata.report
        report.inaccessibleCount += max(0, previousReport.inaccessibleCount - previousReport.inaccessiblePaths.count)
        return ScanResult(root: root, report: report, checkpoint: checkpoint)
    }

    private func makeReport(
        root: FileNode,
        scope: ScanScope,
        kind: ScanKind,
        context: ScanContext,
        progress: ScanProgress
    ) -> ScanReport {
        let inaccessible = context.inaccessible
        return ScanReport(
            rootPath: scope.rootPath,
            options: scope.options,
            kind: kind,
            startedAt: progress.startedAt,
            duration: Date().timeIntervalSince(progress.startedAt),
            fileCount: root.fileCount,
            directoryCount: root.directoryCount,
            logicalSize: root.totalSize,
            physicalSize: root.totalAllocatedSize,
            inaccessiblePaths: inaccessible.paths,
            inaccessibleCount: inaccessible.count
        )
    }
}
