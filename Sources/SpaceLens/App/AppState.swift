import SwiftUI

enum SizeMetric: String, CaseIterable, Sendable {
    case fileSize = "Logical Size"
    case allocatedSize = "Physical Size"
}

/// What treemap and sunburst colors encode.
enum ColorMode: String, CaseIterable, Sendable {
    /// Each top-level folder has its own hue, carried through its subtree.
    case folder
    /// Files are colored by kind (`FileCategory`).
    case kind
}

enum ChartStyle: String, CaseIterable, Sendable {
    case treemap
    case sunburst
    /// Not a chart: the cleanup suggestions for the whole scan.
    case cleanup
}

/// App-wide state: which screen is shown, the current results and scan progress.
///
/// Views observe individual properties, so keep hot values apart: `scanProgress` changes 10 times a second
/// and only the progress view reads it.
@Observable
@MainActor
final class AppState {
    enum Screen: Equatable {
        case welcome
        case scanning
        case results
        case failed(message: String)
    }

    private(set) var screen: Screen = .welcome
    /// Where a scan was started from; cancelling or dismissing its error returns there.
    private var screenBeforeScan: Screen = .welcome
    /// The most recent completed scan. Kept while another scan runs, so cancelling returns to it.
    private(set) var results: ResultsModel?
    /// Sampled progress of the running scan.
    var scanProgress: ScanProgressSnapshot?
    var sizeMetric: SizeMetric = .fileSize
    var colorMode: ColorMode = .folder
    var chartStyle: ChartStyle = .treemap
    var showInspector = true
    var history: [ScanHistoryEntry] = []

    var isScanning: Bool { screen == .scanning }

    func scanStarted(progress: ScanProgressSnapshot) {
        if screen != .scanning { screenBeforeScan = screen }
        scanProgress = progress
        screen = .scanning
    }

    func scanFinished(root: FileNode, report: ScanReport) {
        if let retired = results {
            Self.releaseInBackground(retired.root)
        }
        results = ResultsModel(root: root, report: report)
        scanProgress = nil
        screen = .results
    }

    func scanCancelled() {
        scanProgress = nil
        screen = screenAfterAbandonedScan
    }

    func scanFailed(message: String) {
        scanProgress = nil
        screen = .failed(message: message)
    }

    /// Leaves the current screen for the welcome screen. Results stay loaded.
    func showWelcome() {
        guard !isScanning else { return }
        screen = .welcome
    }

    func showResults() {
        guard results != nil, !isScanning else { return }
        screen = .results
    }

    func dismissError() {
        screen = screenAfterAbandonedScan
    }

    /// Results are only returned to when the scan was started from them (a rescan); a scan started from
    /// the welcome screen goes back there, which still offers "Back to Results".
    private var screenAfterAbandonedScan: Screen {
        screenBeforeScan == .results && results != nil ? .results : .welcome
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
}
