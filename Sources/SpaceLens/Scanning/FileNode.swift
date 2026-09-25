import Foundation

/// A node in the scanned file tree.
///
/// Thread-safety contract (hence `@unchecked Sendable`): a tree is built and mutated by exactly one
/// scan pipeline, then published to the UI. After publication it is treated as immutable and may be
/// read concurrently (UI, treemap layout, snapshot persistence). Incremental rescans never mutate a
/// published tree; they operate on a freshly decoded copy from the snapshot cache.
final class FileNode: Identifiable, Hashable, @unchecked Sendable {
    struct Attributes: OptionSet, Hashable, Sendable {
        let rawValue: UInt16

        static let directory = Attributes(rawValue: 1 << 0)
        static let symlink = Attributes(rawValue: 1 << 1)
        static let hidden = Attributes(rawValue: 1 << 2)
        /// The file has at least one unallocated (sparse) region.
        static let sparse = Attributes(rawValue: 1 << 3)
        /// Transparently compressed (decmpfs); logical size exceeds on-disk size.
        static let compressed = Attributes(rawValue: 1 << 4)
        /// APFS clone: shares some or all of its blocks with other files.
        static let clone = Attributes(rawValue: 1 << 5)
        /// The clone whose physical size carries the blocks shared by its clone family.
        static let cloneOwner = Attributes(rawValue: 1 << 6)
        /// Has more than one hard link; only the first link encountered is kept in the tree.
        static let hardLinked = Attributes(rawValue: 1 << 7)
        static let purgeable = Attributes(rawValue: 1 << 8)
    }

    let name: String
    /// File system object ID (inode). Not unique across volumes; use `id` for identity.
    let fileID: UInt64
    let attributes: Attributes
    let category: FileCategory
    /// Logical size in bytes (what `ls -l` reports, including resource forks).
    let ownSize: Int64
    /// Physical bytes attributed to this node. For APFS clones only the owner of a clone family is
    /// charged for the shared blocks, so summing this over a tree approximates real disk usage.
    let allocatedSize: Int64
    /// APFS clone family identifier, or 0 when the file is not a clone.
    let cloneID: UInt64
    /// Modification time in whole seconds since 1970.
    let modificationTime: Int64

    weak var parent: FileNode?
    var children: [FileNode] = []
    private(set) var directoryChildren: [FileNode] = []
    private(set) var totalSize: Int64 = 0
    private(set) var totalAllocatedSize: Int64 = 0
    private(set) var fileCount: Int = 0
    private(set) var directoryCount: Int = 0

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isDirectory: Bool { attributes.contains(.directory) }

    var modificationDate: Date? {
        modificationTime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(modificationTime))
    }

    /// Absolute path. The root node's name is the absolute scan root path.
    var path: String {
        var components: [String] = []
        var node: FileNode? = self
        while let current = node {
            components.append(current.name)
            node = current.parent
        }
        guard let rootName = components.popLast() else { return "" }
        guard !components.isEmpty else { return rootName }
        let separator = rootName.hasSuffix("/") ? "" : "/"
        return rootName + separator + components.reversed().joined(separator: "/")
    }

    init(
        name: String,
        fileID: UInt64,
        attributes: Attributes,
        category: FileCategory = .other,
        ownSize: Int64 = 0,
        allocatedSize: Int64 = 0,
        cloneID: UInt64 = 0,
        modificationTime: Int64 = 0
    ) {
        self.name = name
        self.fileID = fileID
        self.attributes = attributes
        self.category = category
        self.ownSize = ownSize
        self.allocatedSize = allocatedSize
        self.cloneID = cloneID
        self.modificationTime = modificationTime
        self.totalSize = ownSize
        self.totalAllocatedSize = allocatedSize
        self.fileCount = attributes.contains(.directory) ? 0 : 1
        self.directoryCount = attributes.contains(.directory) ? 1 : 0
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    func addChild(_ child: FileNode) {
        child.parent = self
        children.append(child)
    }

    /// Replaces the children. Detached children lose their parent link so they no longer resolve to a path
    /// inside this tree.
    func setChildren(_ newChildren: [FileNode]) {
        for child in children where child.parent === self { child.parent = nil }
        for child in newChildren { child.parent = self }
        children = newChildren
    }

    /// Recomputes aggregates, sorts children by size and caches directory children for the whole
    /// subtree. Must run before the tree is published.
    func finalizeTree() {
        guard isDirectory else { return }
        var size = ownSize
        var allocated = allocatedSize
        var files = 0
        var dirs = 1

        for child in children {
            child.finalizeTree()
            size += child.totalSize
            allocated += child.totalAllocatedSize
            files += child.fileCount
            dirs += child.directoryCount
        }

        totalSize = size
        totalAllocatedSize = allocated
        fileCount = files
        directoryCount = dirs
        children.sort { $0.totalSize > $1.totalSize }
        directoryChildren = children.filter(\.isDirectory)
    }

    func categoryBreakdown() -> [(category: FileCategory, size: Int64)] {
        var breakdown: [FileCategory: Int64] = [:]
        accumulateCategories(into: &breakdown)
        return breakdown
            .sorted { $0.value > $1.value }
            .map { (category: $0.key, size: $0.value) }
    }

    private func accumulateCategories(into breakdown: inout [FileCategory: Int64]) {
        if !isDirectory {
            breakdown[category, default: 0] += ownSize
        }
        for child in children {
            child.accumulateCategories(into: &breakdown)
        }
    }

    func size(for metric: SizeMetric) -> Int64 {
        switch metric {
        case .fileSize: totalSize
        case .allocatedSize: totalAllocatedSize
        }
    }

    /// Returns the direct child with the given name, if any.
    func child(named name: String) -> FileNode? {
        children.first { $0.name == name }
    }
}
