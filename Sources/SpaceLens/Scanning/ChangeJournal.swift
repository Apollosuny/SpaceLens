import CoreServices
import Foundation
import os
import Synchronization

/// Directories changed since a recorded point in the FSEvents history.
struct ChangeSet: Equatable, Sendable {
    /// Directories whose direct entries changed.
    var directories: Set<String> = []
    /// Directories whose whole subtree must be rescanned (events were coalesced or dropped).
    var recursiveDirectories: Set<String> = []

    var isEmpty: Bool { directories.isEmpty && recursiveDirectories.isEmpty }
    var count: Int { directories.count + recursiveDirectories.count }
}

/// Reads the persistent FSEvents journal to find what changed since a previous scan.
///
/// The journal is per volume and identified by a UUID that changes when its history is reset, so a
/// stored event ID is only meaningful together with the UUID recorded at the same time.
enum ChangeJournal {
    private static let logger = Logger(subsystem: "SpaceLens", category: "ChangeJournal")

    struct Checkpoint: Codable, Hashable, Sendable {
        var eventID: UInt64
        var journalUUID: String
    }

    /// Records the current journal position for the volume containing `path`, or nil when the volume
    /// keeps no FSEvents history (e.g. some external or network volumes).
    static func checkpoint(forPath path: String) -> Checkpoint? {
        guard let uuid = journalUUID(forPath: path) else { return nil }
        return Checkpoint(eventID: FSEventsGetCurrentEventId(), journalUUID: uuid)
    }

    static func journalUUID(forPath path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev)
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// Replays the history since `checkpoint` for `rootPath`. Returns nil when the history cannot be
    /// trusted (journal reset, root changed, event IDs wrapped, timeout); callers must then fall back
    /// to a full scan.
    static func changes(
        since checkpoint: Checkpoint,
        under rootPath: String,
        firmlinks: [Firmlink] = Firmlink.systemFirmlinks(),
        timeout: Duration = .seconds(15)
    ) async -> ChangeSet? {
        guard journalUUID(forPath: rootPath) == checkpoint.journalUUID else {
            logger.info("FSEvents journal changed; full scan required")
            return nil
        }

        let collector = EventCollector(normalizer: PathNormalizer(rootPath: rootPath, firmlinks: firmlinks))
        guard let stream = collector.makeStream(rootPath: rootPath, since: checkpoint.eventID) else {
            return nil
        }
        defer {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            // The stream holds an unretained pointer to the collector; keep it alive until the stream is gone.
            withExtendedLifetime(collector) {}
        }

        let queue = DispatchQueue(label: "SpaceLens.ChangeJournal")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { return nil }

        let timeoutTask = Task {
            try await Task.sleep(for: timeout)
            logger.error("Timed out replaying FSEvents history")
            collector.finish(with: nil)
        }
        defer { timeoutTask.cancel() }

        return await withTaskCancellationHandler {
            await collector.waitForOutcome()
        } onCancel: {
            collector.finish(with: nil)
        }
    }
}

/// Maps journal paths onto the scan root's namespace. FSEvents may report Data-volume paths either via
/// their firmlink (`/Users/x`) or via the Data mount point (`/System/Volumes/Data/Users/x`).
struct PathNormalizer: Sendable {
    let rootPath: String
    let firmlinks: [Firmlink]

    func normalize(_ rawPath: String) -> String? {
        var path = rawPath.count > 1 && rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
        let dataPrefix = ScanScope.dataVolumeMountPoint + "/"
        if path.hasPrefix(dataPrefix) {
            let relative = String(path.dropFirst(dataPrefix.count))
            for firmlink in firmlinks {
                let target = firmlink.dataVolumeRelativePath
                if relative == target || relative.hasPrefix(target + "/") {
                    path = firmlink.path + relative.dropFirst(target.count)
                    break
                }
            }
        }
        guard rootPath == "/" || path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        return path
    }
}

/// Accumulates replayed events and resolves exactly once: with the change set when the replay reaches
/// `HistoryDone`, or with nil when the history is unusable, times out, or the caller is cancelled.
private final class EventCollector: Sendable {
    private struct State {
        var changes = ChangeSet()
        var isFinished = false
        /// Set once finished; `.some(nil)` means the history is unusable.
        var outcome: ChangeSet??
        var waiter: CheckedContinuation<ChangeSet?, Never>?
    }

    private let state = Mutex(State())
    let normalizer: PathNormalizer

    init(normalizer: PathNormalizer) {
        self.normalizer = normalizer
    }

    func waitForOutcome() async -> ChangeSet? {
        await withCheckedContinuation { continuation in
            let ready: ChangeSet?? = state.withLock { state in
                if let outcome = state.outcome { return outcome }
                state.waiter = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func finish(with result: ChangeSet?) {
        let waiter = state.withLock { state -> CheckedContinuation<ChangeSet?, Never>? in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            state.outcome = .some(result)
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: result)
    }

    func makeStream(rootPath: String, since eventID: UInt64) -> FSEventStreamRef? {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let collector = Unmanaged<EventCollector>.fromOpaque(info).takeUnretainedValue()
            let pathArray = unsafeBitCast(paths, to: NSArray.self)
            for index in 0..<count {
                guard let path = pathArray[index] as? String else { continue }
                collector.handle(path: path, flags: flags[index])
            }
        }
        return FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootPath] as CFArray,
            FSEventStreamEventId(eventID),
            0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        )
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
            finish(with: state.withLock { $0.changes })
            return
        }
        let untrustworthy = FSEventStreamEventFlags(
            kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagUnmount
        )
        if flags & untrustworthy != 0 {
            finish(with: nil)
            return
        }
        guard let normalized = normalizer.normalize(path) else { return }
        state.withLock { state in
            guard !state.isFinished else { return }
            let mustScanSubdirectories = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped
            )
            if flags & mustScanSubdirectories != 0 {
                state.changes.recursiveDirectories.insert(normalized)
            } else {
                state.changes.directories.insert(normalized)
            }
        }
    }
}
