import Foundation
import os
import Synchronization

/// Shared, thread-safe state for one scan run.
final class ScanContext: Sendable {
    let scope: ScanScope
    let progress: ScanProgress

    private struct DedupState {
        var hardLinks = Set<UInt64>()
        var cloneFamilies = Set<UInt64>()
    }

    private struct IssueLog {
        var inaccessiblePaths: [String] = []
        var inaccessibleCount = 0
    }

    private let dedup = Mutex(DedupState())
    private let issues = Mutex(IssueLog())

    init(scope: ScanScope, progress: ScanProgress) {
        self.scope = scope
        self.progress = progress
    }

    /// Returns true for the first sighting of a multiply-linked file; later links are skipped so the
    /// file's bytes are counted once.
    func claimHardLink(_ fileID: UInt64) -> Bool {
        dedup.withLock { $0.hardLinks.insert(fileID).inserted }
    }

    /// Returns true for the first member of a pure-clone family, which is charged for the shared blocks.
    func claimCloneFamily(_ cloneID: UInt64) -> Bool {
        dedup.withLock { $0.cloneFamilies.insert(cloneID).inserted }
    }

    /// Pre-populates dedup state from an existing tree (incremental rescans).
    func seed(hardLinks: Set<UInt64>, cloneFamilies: Set<UInt64>) {
        dedup.withLock {
            $0.hardLinks.formUnion(hardLinks)
            $0.cloneFamilies.formUnion(cloneFamilies)
        }
    }

    func recordInaccessible(_ path: String) {
        progress.didFindInaccessibleDirectory()
        issues.withLock {
            $0.inaccessibleCount += 1
            if $0.inaccessiblePaths.count < ScanReport.maxRecordedIssues {
                $0.inaccessiblePaths.append(path)
            }
        }
    }

    var inaccessible: (paths: [String], count: Int) {
        issues.withLock { ($0.inaccessiblePaths.sorted(), $0.inaccessibleCount) }
    }
}

/// Walks directory trees in parallel and builds `FileNode` trees.
///
/// Each directory is read with a single `getattrlistbulk` pass, then its subdirectories are scanned as
/// child tasks, so cancellation propagates through the whole walk. A directory's file descriptor is
/// closed before its children are scanned, which bounds open descriptors by the pool width.
struct FileScanner: Sendable {
    private static let logger = Logger(subsystem: "SpaceLens", category: "Scanner")

    let context: ScanContext

    /// Scans the scope root and returns the finalized tree.
    func scanRoot() async throws -> FileNode {
        try Task.checkCancellation()
        let rootPath = context.scope.rootPath
        var rootStat = stat()
        guard lstat(rootPath, &rootStat) == 0 else {
            throw errno == ENOENT
                ? ScanError.rootNotFound(rootPath)
                : ScanError.rootUnreadable(path: rootPath, code: errno)
        }
        guard rootStat.st_mode & S_IFMT == S_IFDIR else {
            throw ScanError.rootNotDirectory(rootPath)
        }

        let root = FileNode(
            name: rootPath,
            fileID: UInt64(rootStat.st_ino),
            attributes: .directory,
            modificationTime: Int64(rootStat.st_mtimespec.tv_sec)
        )

        context.progress.setPhase(.scanning)
        let listing: DirectoryListing
        do {
            listing = try listDirectory(atPath: rootPath)
        } catch {
            throw ScanError.rootUnreadable(path: rootPath, code: error.code)
        }
        root.setChildren(listing.files + listing.subdirectories.map(\.node))
        try await scanSubdirectories(listing.subdirectories)

        context.progress.setPhase(.finalizing)
        root.finalizeTree()
        return root
    }

    /// Recursively scans `path` into `node`, replacing its children. Unreadable directories are
    /// recorded and left empty.
    func scanDirectory(atPath path: String, into node: FileNode) async throws {
        try Task.checkCancellation()
        let listing: DirectoryListing
        do {
            listing = try listDirectory(atPath: path)
        } catch {
            handleReadError(error)
            return
        }
        node.setChildren(listing.files + listing.subdirectories.map(\.node))
        try await scanSubdirectories(listing.subdirectories)
    }

    func scanSubdirectories(_ subdirectories: [(node: FileNode, path: String)]) async throws {
        switch subdirectories.count {
        case 0:
            return
        case 1:
            try await scanDirectory(atPath: subdirectories[0].path, into: subdirectories[0].node)
        default:
            try await withThrowingTaskGroup(of: Void.self) { group in
                for subdirectory in subdirectories {
                    group.addTask {
                        try await scanDirectory(atPath: subdirectory.path, into: subdirectory.node)
                    }
                }
                try await group.waitForAll()
            }
        }
    }

    func handleReadError(_ error: DirectoryReadError) {
        // Vanished mid-scan: not an issue worth reporting.
        if error.isNotFound { return }
        // Dataless (not yet downloaded) cloud directory; materialization is disabled during scans.
        if error.code == EDEADLK { return }
        Self.logger.debug("Cannot read \(error.path, privacy: .private): errno \(error.code)")
        context.recordInaccessible(error.path)
    }

    // MARK: - Listing

    struct DirectoryListing {
        var files: [FileNode] = []
        /// Subdirectories to descend into, with their not-yet-populated nodes.
        var subdirectories: [(node: FileNode, path: String)] = []
    }

    /// Reads one directory level. Files become finished nodes; subdirectories become empty nodes.
    func listDirectory(atPath path: String) throws(DirectoryReadError) -> DirectoryListing {
        let scope = context.scope
        let entries = try DirectoryReader.readEntries(atPath: path)

        var listing = DirectoryListing()
        var logicalBytes: Int64 = 0
        var physicalBytes: Int64 = 0

        for entry in entries where scope.includes(entry) {
            switch entry.kind {
            case .directory:
                let childPath = ScanScope.childPath(path, entry.name)
                guard scope.shouldDescend(into: entry, atPath: childPath) else { continue }
                listing.subdirectories.append((makeDirectoryNode(entry), childPath))
            case .regularFile, .symlink:
                guard let node = makeFileNode(entry) else { continue }
                logicalBytes += node.ownSize
                physicalBytes += node.allocatedSize
                listing.files.append(node)
            case .other:
                // Sockets, FIFOs and device nodes occupy no data blocks.
                continue
            }
        }

        context.progress.didReadDirectory(
            path: path,
            files: listing.files.count,
            logical: logicalBytes,
            physical: physicalBytes
        )
        return listing
    }

    func makeDirectoryNode(_ entry: DirectoryEntry) -> FileNode {
        var attributes: FileNode.Attributes = .directory
        if entry.isHidden { attributes.insert(.hidden) }
        return FileNode(
            name: entry.name,
            fileID: entry.fileID,
            attributes: attributes,
            modificationTime: entry.modificationTime
        )
    }

    /// Builds a leaf node, applying hard-link and clone de-duplication. Returns nil for repeated hard links.
    func makeFileNode(_ entry: DirectoryEntry) -> FileNode? {
        var attributes: FileNode.Attributes = []
        if entry.kind == .regularFile && entry.linkCount > 1 {
            guard context.claimHardLink(entry.fileID) else { return nil }
            attributes.insert(.hardLinked)
        }
        if entry.kind == .symlink { attributes.insert(.symlink) }
        if entry.isHidden { attributes.insert(.hidden) }
        if entry.isSparse { attributes.insert(.sparse) }
        if entry.isCompressed { attributes.insert(.compressed) }
        if entry.isPurgeable { attributes.insert(.purgeable) }

        var physicalSize = entry.allocatedSize
        var cloneID: UInt64 = 0
        if entry.mayShareBlocks {
            attributes.insert(.clone)
            // Pure clones share every block, so the family's data is charged once, to the first member
            // seen. Partial clones cannot be matched to their family and are charged in full, which
            // matches Finder's "size on disk".
            if entry.sharesAllBlocks, let familyID = entry.cloneID {
                cloneID = familyID
                if context.claimCloneFamily(familyID) {
                    attributes.insert(.cloneOwner)
                } else {
                    physicalSize = entry.privateSize ?? 0
                }
            }
        }

        let category: FileCategory = entry.kind == .symlink
            ? .other
            : FileExtensionMap.category(for: Self.pathExtension(of: entry.name))

        return FileNode(
            name: entry.name,
            fileID: entry.fileID,
            attributes: attributes,
            category: category,
            ownSize: entry.logicalSize,
            allocatedSize: physicalSize,
            cloneID: cloneID,
            modificationTime: entry.modificationTime
        )
    }

    private static func pathExtension(of name: String) -> String {
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else { return "" }
        return String(name[name.index(after: dotIndex)...])
    }
}

/// Disables materialization of dataless (cloud placeholder) files and directories for the process
/// while at least one scan runs, so scanning never triggers iCloud / File Provider downloads.
enum DatalessMaterializationPolicy {
    private static let activeScans = Mutex<(count: Int, previous: Int32)>((0, 0))

    static func withMaterializationDisabled<T>(_ body: () async throws -> T) async rethrows -> T {
        activeScans.withLock { state in
            if state.count == 0 {
                state.previous = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS)
                setiopolicy_np(
                    IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,
                    IOPOL_SCOPE_PROCESS,
                    IOPOL_MATERIALIZE_DATALESS_FILES_OFF
                )
            }
            state.count += 1
        }
        defer {
            activeScans.withLock { state in
                state.count -= 1
                if state.count == 0 && state.previous >= 0 {
                    setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, state.previous)
                }
            }
        }
        return try await body()
    }
}
