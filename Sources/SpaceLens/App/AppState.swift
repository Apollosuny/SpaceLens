import SwiftUI

enum ScanStatus: Equatable {
    case idle
    case scanning(ScanProgressSnapshot)
    case completed
    case error(String)
}

enum SizeMetric: String, CaseIterable, Sendable {
    case fileSize = "Logical Size"
    case allocatedSize = "Physical Size"
}

@Observable
@MainActor
final class AppState {
    var scanStatus: ScanStatus = .idle
    var rootNode: FileNode?
    var treemapRoot: FileNode?
    var selectedNode: FileNode?
    var breadcrumbs: [FileNode] = []
    var sizeMetric: SizeMetric = .fileSize
    var showInspector: Bool = true
    /// Report of the scan currently displayed.
    var lastReport: ScanReport?
    var history: [ScanHistoryEntry] = []

    var isScanning: Bool {
        if case .scanning = scanStatus { return true }
        return false
    }

    var hasData: Bool {
        rootNode != nil
    }

    func drillDown(to node: FileNode) {
        guard node.isDirectory else { return }
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateTo(breadcrumb node: FileNode) {
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = node
            selectedNode = node
            rebuildBreadcrumbs()
        }
    }

    func navigateUp() {
        guard let current = treemapRoot, let parent = current.parent else { return }
        withAnimation(.spring(duration: 0.3)) {
            treemapRoot = parent
            selectedNode = parent
            rebuildBreadcrumbs()
        }
    }

    func setScanCompleted(root: FileNode, report: ScanReport) {
        rootNode = root
        treemapRoot = root
        selectedNode = root
        lastReport = report
        scanStatus = .completed
        rebuildBreadcrumbs()
    }

    func reset() {
        if let retiredRoot = rootNode {
            Self.releaseInBackground(retiredRoot)
        }
        scanStatus = .idle
        rootNode = nil
        treemapRoot = nil
        selectedNode = nil
        breadcrumbs = []
        lastReport = nil
    }

    /// Deallocating a tree of millions of nodes takes hundreds of milliseconds. Keep the root alive on a
    /// background task until views have dropped their references, so the cascade of deinits runs there
    /// instead of stalling the main thread.
    private static func releaseInBackground(_ root: FileNode) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(2))
            withExtendedLifetime(root) {}
        }
    }

    private func rebuildBreadcrumbs() {
        var crumbs: [FileNode] = []
        var node = treemapRoot
        while let current = node {
            crumbs.insert(current, at: 0)
            node = current.parent
        }
        breadcrumbs = crumbs
    }
}
