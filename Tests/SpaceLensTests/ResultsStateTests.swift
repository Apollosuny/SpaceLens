import Foundation
import Testing
@testable import SpaceLens

@MainActor
@Suite("Results state")
struct ResultsStateTests {
    /// /scan ─ docs ─ reports ─ q1.pdf
    ///       │      └ notes.txt
    ///       └ media ─ clip.mov
    private let root = FileNode(name: "/scan", fileID: 0, attributes: .directory)
    private let docs = FileNode(name: "docs", fileID: 0, attributes: .directory)
    private let reports = FileNode(name: "reports", fileID: 0, attributes: .directory)
    private let media = FileNode(name: "media", fileID: 0, attributes: .directory)
    private let report = FileNode(name: "q1.pdf", fileID: 0, attributes: [], category: .documents, ownSize: 300, allocatedSize: 300)
    private let clip = FileNode(name: "clip.mov", fileID: 0, attributes: [], category: .video, ownSize: 500, allocatedSize: 500)

    init() {
        root.addChild(docs)
        root.addChild(media)
        docs.addChild(reports)
        docs.addChild(FileNode(name: "notes.txt", fileID: 0, attributes: [], category: .documents, ownSize: 100, allocatedSize: 100))
        reports.addChild(report)
        media.addChild(clip)
        root.finalizeTree()
    }

    private func makeReport() -> ScanReport {
        ScanReport(rootPath: "/scan", options: ScanOptions(), kind: .full, startedAt: Date(), duration: 1,
                   fileCount: 3, directoryCount: 4, logicalSize: 900, physicalSize: 900,
                   inaccessiblePaths: [], inaccessibleCount: 0)
    }

    private func progress() -> ScanProgressSnapshot {
        ScanProgress().snapshot()
    }

    @Test("Cancelling returns to the screen the scan started from; a finished scan replaces the results")
    func scanLifecycle() {
        let state = AppState()
        state.scanStarted(progress: progress())
        state.scanCancelled()
        #expect(state.screen == .welcome)

        state.scanStarted(progress: progress())
        state.scanFinished(root: root, report: makeReport())
        let firstResults = state.results
        #expect(state.screen == .results)
        #expect(state.scanProgress == nil)

        // A rescan from the results goes back to them.
        state.scanStarted(progress: progress())
        state.scanCancelled()
        #expect(state.screen == .results)
        #expect(state.results === firstResults)

        // A new scan started from the welcome screen goes back there, keeping the results loaded.
        state.showWelcome()
        state.scanStarted(progress: progress())
        state.scanCancelled()
        #expect(state.screen == .welcome)
        #expect(state.results === firstResults)

        state.showResults()
        state.scanStarted(progress: progress())
        state.scanFailed(message: "gone")
        #expect(state.screen == .failed(message: "gone"))
        state.dismissError()
        #expect(state.screen == .results)
    }

    @Test("Opening a folder selects it, derives breadcrumbs and reveals it in the sidebar")
    func openFolder() {
        let results = ResultsModel(root: root, report: makeReport())
        results.open(reports)

        #expect(results.viewRoot === reports)
        #expect(results.selection === reports)
        #expect(results.breadcrumbs.map(\.name) == ["/scan", "docs", "reports"])
        #expect(results.expandedFolders == [docs])

        results.navigateUp()
        #expect(results.viewRoot === docs)
        #expect(results.selection === reports)
        #expect(results.canNavigateUp)

        results.open(report)
        #expect(results.viewRoot === docs, "files cannot be opened")
    }

    @Test("Selecting outside the shown folder moves the treemap to the selection's parent")
    func selectOutsideViewRoot() {
        let results = ResultsModel(root: root, report: makeReport())
        results.open(reports)

        results.select(report)
        #expect(results.viewRoot === reports, "inside the shown folder: the treemap stays")

        results.select(clip)
        #expect(results.selection === clip)
        #expect(results.viewRoot === media)
        #expect(results.expandedFolders.contains(media))
    }

    @Test("Navigating resets the zoom")
    func navigationResetsZoom() {
        let results = ResultsModel(root: root, report: makeReport())
        results.viewport.viewSize = CGSize(width: 400, height: 300)
        results.viewport.zoomIn()
        #expect(results.viewport.canZoomOut)

        results.open(docs)
        #expect(results.viewport.transform == TreemapTransform())
    }

    @Test("Zoom stays within bounds and panning cannot reveal past the content edges")
    func viewportClamping() {
        let viewport = TreemapViewport()
        viewport.viewSize = CGSize(width: 400, height: 300)
        viewport.zoomOut()
        #expect(viewport.transform == TreemapTransform())

        viewport.zoom(by: 1, around: CGPoint(x: 200, y: 150))
        #expect(viewport.transform.zoom == 2)
        #expect(viewport.transform.pan == CGPoint(x: -200, y: -150))

        viewport.pan(dx: 1000, dy: -1000)
        #expect(viewport.transform.pan == CGPoint(x: 0, y: -300))

        for _ in 0..<50 { viewport.zoomIn() }
        #expect(viewport.transform.zoom == TreemapViewport.maxZoom)
        #expect(!viewport.canZoomIn)
    }

    @Test("Category breakdowns are cached per folder")
    func breakdownCache() async {
        let results = ResultsModel(root: root, report: makeReport())
        let first = await results.categoryBreakdown(of: root)
        let second = await results.categoryBreakdown(of: root)
        #expect(first.map(\.category) == [.video, .documents])
        #expect(first.map(\.size) == [500, 400])
        #expect(second.map(\.size) == first.map(\.size))
    }
}
