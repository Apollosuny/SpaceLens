import SwiftUI

typealias CategoryBreakdown = [(category: FileCategory, size: Int64)]

/// Navigation and selection within one completed scan. The sidebar, treemap, breadcrumb and inspector
/// all read and write this single model, so they cannot drift apart.
@Observable
@MainActor
final class ResultsModel {
    let root: FileNode
    let report: ScanReport
    let viewport = TreemapViewport()

    /// The folder the treemap shows.
    private(set) var viewRoot: FileNode
    private(set) var selection: FileNode?
    /// Folders expanded in the sidebar.
    private(set) var expandedFolders: Set<FileNode> = []

    /// Category totals walk whole subtrees (millions of nodes at a volume root), so each is computed once,
    /// off the main actor, and shared by the legend and the inspector.
    @ObservationIgnored private var breakdowns: [FileNode: CategoryBreakdown] = [:]
    @ObservationIgnored private var pendingBreakdowns: [FileNode: Task<CategoryBreakdown, Never>] = [:]

    init(root: FileNode, report: ScanReport) {
        self.root = root
        self.report = report
        self.viewRoot = root
        self.selection = root
    }

    /// The path from the scan root to `viewRoot`.
    var breadcrumbs: [FileNode] {
        var crumbs: [FileNode] = []
        var node: FileNode? = viewRoot
        while let current = node {
            crumbs.append(current)
            if current === root { break }
            node = current.parent
        }
        return crumbs.reversed()
    }

    var canNavigateUp: Bool { viewRoot !== root && viewRoot.parent != nil }

    /// Shows `folder` in the treemap and selects it.
    func open(_ folder: FileNode) {
        guard folder.isDirectory else { return }
        setViewRoot(folder)
        setSelection(folder)
    }

    /// Shows the enclosing folder, keeping the folder just left selected.
    func navigateUp() {
        guard canNavigateUp, let parent = viewRoot.parent else { return }
        let previous = viewRoot
        setViewRoot(parent)
        setSelection(previous)
    }

    /// Selects `node`. When it lies outside the treemap's folder (picked in the sidebar), the treemap moves
    /// to its parent so it is visible among its siblings.
    func select(_ node: FileNode?) {
        setSelection(node)
        guard let node, !node.isInSubtree(of: viewRoot) else { return }
        setViewRoot(node.parent ?? node)
    }

    func setExpanded(_ folder: FileNode, _ isExpanded: Bool) {
        if isExpanded {
            expandedFolders.insert(folder)
        } else {
            expandedFolders.remove(folder)
        }
    }

    func categoryBreakdown(of node: FileNode) async -> CategoryBreakdown {
        if let cached = breakdowns[node] { return cached }
        let task = pendingBreakdowns[node] ?? {
            let task = Task.detached(priority: .userInitiated) { node.categoryBreakdown() }
            pendingBreakdowns[node] = task
            return task
        }()
        let breakdown = await task.value
        breakdowns[node] = breakdown
        pendingBreakdowns[node] = nil
        return breakdown
    }

    private func setViewRoot(_ folder: FileNode) {
        guard folder !== viewRoot else { return }
        viewRoot = folder
        viewport.reset()
        revealInSidebar(folder)
    }

    private func setSelection(_ node: FileNode?) {
        guard node !== selection else { return }
        selection = node
        if let node { revealInSidebar(node) }
    }

    /// Expands the sidebar down to `node` (the sidebar lists folders only, so a file reveals its folder).
    private func revealInSidebar(_ node: FileNode) {
        var missing: [FileNode] = []
        var ancestor = node.parent
        while let current = ancestor, current !== root {
            if !expandedFolders.contains(current) { missing.append(current) }
            ancestor = current.parent
        }
        if !missing.isEmpty { expandedFolders.formUnion(missing) }
    }
}

extension FileNode {
    /// Whether this node is `ancestor` or lies below it.
    func isInSubtree(of ancestor: FileNode) -> Bool {
        var node: FileNode? = self
        while let current = node {
            if current === ancestor { return true }
            node = current.parent
        }
        return false
    }
}
