import Foundation
import Synchronization

struct ScanOptions: Codable, Hashable, Sendable {
    /// Include dot-files and items flagged `UF_HIDDEN`. On by default: hidden data still occupies disk.
    var includeHiddenFiles: Bool = true
}

enum ScanMode: Sendable {
    /// Reuse the cached snapshot and re-read only directories changed since then, when possible.
    case automatic
    /// Always walk the whole tree.
    case full
}

enum ScanKind: Codable, Hashable, Sendable {
    case full
    case incremental(changedDirectories: Int)
}

/// Summary of a completed scan; persisted in scan history.
struct ScanReport: Codable, Hashable, Sendable {
    static let maxRecordedIssues = 200

    var rootPath: String
    var options: ScanOptions
    var kind: ScanKind
    var startedAt: Date
    var duration: TimeInterval
    var fileCount: Int
    var directoryCount: Int
    var logicalSize: Int64
    var physicalSize: Int64
    /// Directories that could not be read (permissions, TCC). Capped at `maxRecordedIssues`.
    var inaccessiblePaths: [String]
    var inaccessibleCount: Int
}

enum ScanPhase: Equatable, Sendable {
    case preparing
    case scanning
    case loadingCache
    case applyingChanges(directoryCount: Int)
    case finalizing
}

struct ScanProgressSnapshot: Equatable, Sendable {
    var phase: ScanPhase
    var fileCount: Int
    var directoryCount: Int
    var logicalBytes: Int64
    var physicalBytes: Int64
    var inaccessibleCount: Int
    var currentPath: String
    var startedAt: Date
    /// Expected physical bytes for the scan root (volume used space), when known.
    var estimatedTotalBytes: Int64?

    /// Fraction complete in 0...0.99, or nil when the total is unknown.
    var fractionCompleted: Double? {
        guard phase == .scanning, let total = estimatedTotalBytes, total > 0 else { return nil }
        return min(0.99, Double(physicalBytes) / Double(total))
    }
}

/// Lock-free progress counters written by scan workers and sampled by the UI at a fixed rate.
/// Decoupling sampling from production keeps the main thread load constant regardless of scan speed.
final class ScanProgress: Sendable {
    let startedAt: Date
    let estimatedTotalBytes: Int64?

    private let files = Atomic<Int>(0)
    private let directories = Atomic<Int>(0)
    private let logicalBytes = Atomic<Int64>(0)
    private let physicalBytes = Atomic<Int64>(0)
    private let inaccessible = Atomic<Int>(0)
    private let state = Mutex<(phase: ScanPhase, currentPath: String)>((.preparing, ""))

    init(startedAt: Date = Date(), estimatedTotalBytes: Int64? = nil) {
        self.startedAt = startedAt
        self.estimatedTotalBytes = estimatedTotalBytes
    }

    func setPhase(_ phase: ScanPhase) {
        state.withLock { $0.phase = phase }
    }

    func didReadDirectory(path: String, files fileCount: Int, logical: Int64, physical: Int64) {
        directories.add(1, ordering: .relaxed)
        files.add(fileCount, ordering: .relaxed)
        logicalBytes.add(logical, ordering: .relaxed)
        physicalBytes.add(physical, ordering: .relaxed)
        state.withLock { $0.currentPath = path }
    }

    func didFindInaccessibleDirectory() {
        inaccessible.add(1, ordering: .relaxed)
    }

    func snapshot() -> ScanProgressSnapshot {
        let (phase, currentPath) = state.withLock { ($0.phase, $0.currentPath) }
        return ScanProgressSnapshot(
            phase: phase,
            fileCount: files.load(ordering: .relaxed),
            directoryCount: directories.load(ordering: .relaxed),
            logicalBytes: logicalBytes.load(ordering: .relaxed),
            physicalBytes: physicalBytes.load(ordering: .relaxed),
            inaccessibleCount: inaccessible.load(ordering: .relaxed),
            currentPath: currentPath,
            startedAt: startedAt,
            estimatedTotalBytes: estimatedTotalBytes
        )
    }
}

enum ScanError: LocalizedError, Equatable, Sendable {
    case rootNotFound(String)
    case rootNotDirectory(String)
    case rootUnreadable(path: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .rootNotFound(let path):
            "“\(path)” no longer exists."
        case .rootNotDirectory(let path):
            "“\(path)” is not a folder."
        case .rootUnreadable(let path, let code):
            "“\(path)” could not be read (\(String(cString: strerror(code))))."
        }
    }
}
