import Foundation

/// Brings a cached tree up to date by re-reading only the directories reported as changed.
///
/// Operates on a private tree decoded from the snapshot cache (never on a published tree), mutating it
/// in place:
/// 1. Changed paths are resolved to the deepest cached directory; missing paths fall back to their
///    nearest cached ancestor, whose re-listing discovers the new subtree.
/// 2. Targets inside a recursively-dirty subtree are dropped.
/// 3. De-duplication state (hard links, clone families) is seeded from the parts of the tree that are
///    kept, so re-listed files are charged consistently with the rest of the tree.
/// 4. Changed directories are re-listed (one level). Unchanged subdirectories keep their cached subtree
///    (matched by name and file ID); new ones are scanned in full, as are recursively-dirty ones.
struct IncrementalScanner: Sendable {
    /// Beyond this many changed directories a full scan is typically as fast and simpler to trust.
    static let maxChangedDirectories = 50_000

    let scanner: FileScanner

    /// Returns the updated, finalized tree, or nil when a full scan is required instead.
    func apply(_ changes: ChangeSet, to root: FileNode) async throws -> FileNode? {
        guard changes.count <= Self.maxChangedDirectories else { return nil }
        let rootPath = scanner.context.scope.rootPath
        let resolver = TreeResolver(root: root, rootPath: rootPath)

        var recursiveTargets = Set<FileNode>()
        var relistTargets = Set<FileNode>()
        for path in changes.recursiveDirectories {
            switch resolver.resolve(path) {
            case .exact(let node): recursiveTargets.insert(node)
            case .ancestor(let node): relistTargets.insert(node)
            case .outside: continue
            }
        }
        for path in changes.directories {
            switch resolver.resolve(path) {
            case .exact(let node), .ancestor(let node): relistTargets.insert(node)
            case .outside: continue
            }
        }

        if recursiveTargets.contains(root) { return nil }
        recursiveTargets = recursiveTargets.filter { !$0.hasAncestor(in: recursiveTargets) }
        relistTargets = relistTargets.filter { !recursiveTargets.contains($0) && !$0.hasAncestor(in: recursiveTargets) }

        let context = scanner.context
        context.progress.setPhase(.applyingChanges(directoryCount: recursiveTargets.count + relistTargets.count))
        seedDeduplication(from: root, skippingSubtrees: recursiveTargets, skippingFilesOf: relistTargets)

        // Phase A: re-list changed directories concurrently, then apply the results sequentially.
        let listings = try await relist(Array(relistTargets))
        var directoriesToScan: [(node: FileNode, path: String)] = []
        for (node, outcome) in listings {
            switch outcome {
            case .listed(let listing):
                directoriesToScan += merge(listing, into: node)
            case .removed:
                if let parent = node.parent {
                    parent.setChildren(parent.children.filter { $0 !== node })
                }
            case .unreadable(let error):
                scanner.handleReadError(error)
                node.setChildren([])
            }
        }

        // Phase B: full scans of new directories and of recursively-dirty subtrees still in the tree.
        for node in recursiveTargets where node.isAttached(to: root) {
            directoriesToScan.append((node, node.path))
        }
        try await scanner.scanSubdirectories(directoriesToScan)

        context.progress.setPhase(.finalizing)
        root.finalizeTree()
        return root
    }

    private enum RelistOutcome: Sendable {
        case listed(FileScanner.DirectoryListing)
        case removed
        case unreadable(DirectoryReadError)
    }

    private func relist(_ nodes: [FileNode]) async throws -> [(FileNode, RelistOutcome)] {
        let scanner = scanner
        return try await withThrowingTaskGroup(of: (FileNode, RelistOutcome).self) { group in
            for node in nodes {
                let path = node.path
                group.addTask {
                    try Task.checkCancellation()
                    do throws(DirectoryReadError) {
                        return (node, .listed(try scanner.listDirectory(atPath: path)))
                    } catch {
                        return (node, error.isNotFound ? .removed : .unreadable(error))
                    }
                }
            }
            var results: [(FileNode, RelistOutcome)] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    /// Replaces `node`'s children with the fresh listing, reusing cached subtrees for subdirectories that
    /// still exist. Returns the subdirectories that are new and need a full scan.
    private func merge(
        _ listing: FileScanner.DirectoryListing,
        into node: FileNode
    ) -> [(node: FileNode, path: String)] {
        var cachedDirectories: [String: FileNode] = [:]
        for child in node.children where child.isDirectory {
            cachedDirectories[child.name] = child
        }

        var children = listing.files
        var newDirectories: [(node: FileNode, path: String)] = []
        for subdirectory in listing.subdirectories {
            if let cached = cachedDirectories[subdirectory.node.name],
               cached.fileID == subdirectory.node.fileID {
                children.append(cached)
            } else {
                children.append(subdirectory.node)
                newDirectories.append(subdirectory)
            }
        }
        node.setChildren(children)
        return newDirectories
    }

    private func seedDeduplication(
        from root: FileNode,
        skippingSubtrees skippedSubtrees: Set<FileNode>,
        skippingFilesOf relisted: Set<FileNode>
    ) {
        var hardLinks = Set<UInt64>()
        var cloneFamilies = Set<UInt64>()
        var stack = [root]
        while let directory = stack.popLast() {
            let skipFiles = relisted.contains(directory)
            for child in directory.children {
                if child.isDirectory {
                    if !skippedSubtrees.contains(child) { stack.append(child) }
                } else if !skipFiles {
                    if child.attributes.contains(.hardLinked) { hardLinks.insert(child.fileID) }
                    if child.attributes.contains(.cloneOwner) { cloneFamilies.insert(child.cloneID) }
                }
            }
        }
        scanner.context.seed(hardLinks: hardLinks, cloneFamilies: cloneFamilies)
    }
}

/// Resolves absolute paths to directory nodes of a tree, caching per-directory name lookups.
private final class TreeResolver {
    enum Resolution {
        case exact(FileNode)
        /// The path is not in the tree; this is its deepest cached ancestor directory.
        case ancestor(FileNode)
        case outside
    }

    private let root: FileNode
    private let rootPath: String
    private var lookups: [ObjectIdentifier: [String: FileNode]] = [:]

    init(root: FileNode, rootPath: String) {
        self.root = root
        self.rootPath = rootPath
    }

    func resolve(_ path: String) -> Resolution {
        guard path == rootPath || path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") else { return .outside }
        let relative = path.dropFirst(rootPath.count)
        var node = root
        for component in relative.split(separator: "/") {
            guard let next = directoryChild(of: node, named: String(component)) else { return .ancestor(node) }
            node = next
        }
        return .exact(node)
    }

    private func directoryChild(of node: FileNode, named name: String) -> FileNode? {
        let key = ObjectIdentifier(node)
        if let lookup = lookups[key] { return lookup[name] }
        var lookup: [String: FileNode] = [:]
        for child in node.children where child.isDirectory {
            lookup[child.name] = child
        }
        lookups[key] = lookup
        return lookup[name]
    }
}

private extension FileNode {
    func hasAncestor(in nodes: Set<FileNode>) -> Bool {
        var current = parent
        while let node = current {
            if nodes.contains(node) { return true }
            current = node.parent
        }
        return false
    }

    func isAttached(to root: FileNode) -> Bool {
        var current: FileNode? = self
        while let node = current {
            if node === root { return true }
            current = node.parent
        }
        return false
    }
}
