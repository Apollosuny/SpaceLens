import SwiftUI

struct ContentView: View {
    let coordinator: ScanCoordinator

    @Environment(AppState.self) private var appState
    @AppStorage("includeHiddenFiles") private var includeHiddenFiles = true
    /// Plain state bindings, only reassigned when the screen changes: a binding whose getter disagrees with
    /// what AppKit just set makes the split view re-lay out the window endlessly.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly
    /// The user's sidebar choice on the results screen, restored when returning to it.
    @State private var resultsSidebarVisibility: NavigationSplitViewVisibility = .all
    @State private var inspectorPresented = false

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            Group {
                if let results = appState.results, appState.screen == .results {
                    DirectoryTreeView(results: results, sizeMetric: appState.sizeMetric, colorMode: appState.colorMode)
                } else {
                    ContentUnavailableView("No Scan", systemImage: "internaldrive", description: Text("Scan a disk or folder to browse its folders here."))
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
        } detail: {
            detail
        }
        .inspector(isPresented: $inspectorPresented) {
            Group {
                if let results = appState.results {
                    InspectorColumn(results: results, sizeMetric: appState.sizeMetric)
                }
            }
            .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
        }
        .toolbar {
            if appState.screen == .results, let results = appState.results {
                ToolbarItem(placement: .navigation) {
                    BackButton(results: results)
                }

                ToolbarItem(placement: .primaryAction) {
                    Picker("Size", selection: $state.sizeMetric) {
                        Text("Logical").tag(SizeMetric.fileSize)
                        Text("Physical").tag(SizeMetric.allocatedSize)
                    }
                    .pickerStyle(.segmented)
                    .help("Logical size is what files contain; physical size is the disk space they occupy")
                }

                ToolbarItem(placement: .primaryAction) {
                    Picker("View", selection: $state.chartStyle) {
                        Label("Treemap", systemImage: "square.grid.2x2").tag(ChartStyle.treemap)
                        Label("Sunburst", systemImage: "chart.pie").tag(ChartStyle.sunburst)
                        Label("Cleanup", systemImage: "sparkles").tag(ChartStyle.cleanup)
                    }
                    .pickerStyle(.segmented)
                    .labelStyle(.iconOnly)
                    .help("Show folders as a treemap or as rings, or list cleanup suggestions")
                }

                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Color By", selection: $state.colorMode) {
                            Text("Folder").tag(ColorMode.folder)
                            Text("Kind").tag(ColorMode.kind)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Colors", systemImage: "paintpalette")
                    }
                    .help("Color by top-level folder or by file kind")
                }

                if appState.chartStyle == .treemap {
                    ToolbarItem(placement: .primaryAction) {
                        ZoomControls(viewport: results.viewport)
                    }
                }

                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("Full Rescan") {
                            coordinator.rescan(mode: .full)
                        }
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    } primaryAction: {
                        coordinator.rescan(mode: .automatic)
                    }
                    .help("Rescan, re-reading only folders changed since the last scan")

                    Button {
                        appState.showWelcome()
                    } label: {
                        Label("New Scan", systemImage: "internaldrive")
                    }
                    .help("Choose another disk or folder")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        inspectorPresented.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help("Show or hide the inspector")
                }
            }
        }
        .onChange(of: appState.screen, initial: true) { _, screen in
            updateColumns(for: screen)
        }
        .onChange(of: sidebarVisibility) { _, visibility in
            if appState.screen == .results { resultsSidebarVisibility = visibility }
        }
        .onChange(of: inspectorPresented) { _, isPresented in
            if appState.screen == .results { appState.showInspector = isPresented }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.screen {
        case .welcome:
            WelcomeView(
                history: appState.history,
                includeHiddenFiles: $includeHiddenFiles,
                onVolumeSelected: { path in
                    coordinator.startScan(path: path, options: ScanOptions(includeHiddenFiles: includeHiddenFiles))
                },
                onClearHistory: { coordinator.clearHistory() },
                onReturnToResults: appState.results == nil ? nil : { appState.showResults() }
            )
            .navigationTitle("SpaceLens")

        case .scanning:
            ScanProgressView(onCancel: { coordinator.cancel() })
                .navigationTitle("SpaceLens")

        case .results:
            if let results = appState.results {
                ResultsView(
                    results: results,
                    sizeMetric: appState.sizeMetric,
                    colorMode: appState.colorMode,
                    chartStyle: appState.chartStyle,
                    onShowInChart: { node in
                        appState.chartStyle = .treemap
                        results.select(node)
                    }
                )
            }

        case let .failed(message):
            ContentUnavailableView {
                Label("Scan Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("OK") {
                    appState.dismissError()
                }
                .prominentGlassButtonStyle()
            }
            .navigationTitle("SpaceLens")
        }
    }

    /// The sidebar and inspector only belong to the results screen; elsewhere they start hidden but the
    /// user can still open them.
    private func updateColumns(for screen: AppState.Screen) {
        let showsResults = screen == .results
        sidebarVisibility = showsResults ? resultsSidebarVisibility : .detailOnly
        inspectorPresented = showsResults && appState.showInspector
    }
}

// MARK: - Toolbar Controls

/// Separate views so only they re-render when navigation or zoom changes.
private struct BackButton: View {
    let results: ResultsModel

    var body: some View {
        Button {
            results.navigateUp()
        } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .help("Show the enclosing folder")
        .disabled(!results.canNavigateUp)
    }
}

private struct ZoomControls: View {
    let viewport: TreemapViewport

    var body: some View {
        ControlGroup {
            Button {
                viewport.zoomOut()
            } label: {
                Label("Zoom Out", systemImage: "minus.magnifyingglass")
            }
            .keyboardShortcut("-")
            .disabled(!viewport.canZoomOut)

            Button {
                viewport.reset()
            } label: {
                Label("Actual Size", systemImage: "1.magnifyingglass")
            }
            .keyboardShortcut("0")
            .disabled(!viewport.canZoomOut)

            Button {
                viewport.zoomIn()
            } label: {
                Label("Zoom In", systemImage: "plus.magnifyingglass")
            }
            .keyboardShortcut("+")
            .disabled(!viewport.canZoomIn)
        }
    }
}

// MARK: - Inspector

private struct InspectorColumn: View {
    let results: ResultsModel
    let sizeMetric: SizeMetric

    var body: some View {
        if let selected = results.selection {
            DetailPanelView(node: selected, results: results, sizeMetric: sizeMetric)
        } else {
            ContentUnavailableView("No Selection", systemImage: "square.dashed", description: Text("Select a folder or file to see its details."))
        }
    }
}

// MARK: - Inaccessible Folders Banner

struct InaccessibleFoldersBanner: View {
    private static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )

    let report: ScanReport
    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text("\(report.inaccessibleCount.formatted()) folders couldn’t be read, so sizes may be understated.")
            Spacer()
            Button("Show") { showsDetails.toggle() }
                .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                    InaccessibleFoldersList(report: report)
                }
            if let url = Self.fullDiskAccessSettingsURL {
                Button("Grant Full Disk Access…") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct InaccessibleFoldersList: View {
    let report: ScanReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Skipped Folders")
                .font(.headline)
            List(report.inaccessiblePaths, id: \.self) { path in
                Text(path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .frame(width: 480, height: 260)
            if report.inaccessibleCount > report.inaccessiblePaths.count {
                Text("And \((report.inaccessibleCount - report.inaccessiblePaths.count).formatted()) more.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("After granting Full Disk Access, relaunch SpaceLens and rescan.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    let breadcrumbs: [FileNode]
    let sizeMetric: SizeMetric
    let onNavigate: (FileNode) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        let isCurrent = index == breadcrumbs.count - 1
                        Button {
                            onNavigate(node)
                        } label: {
                            Label {
                                Text(node.displayName)
                                    .fontWeight(isCurrent ? .semibold : .regular)
                                    .lineLimit(1)
                            } icon: {
                                if index == 0 {
                                    Image(systemName: node.name == "/" ? "internaldrive" : "folder")
                                } else if isCurrent {
                                    Image(systemName: "folder.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                        .disabled(isCurrent)
                    }
                }
            }

            if let current = breadcrumbs.last {
                Text("\(current.fileCount.formatted()) files · \(current.directoryCount.formatted()) folders")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize()
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .overlay(alignment: .bottom) { Divider() }
    }
}

extension FileNode {
    /// Name for display: a scan root's name is its absolute path, so show the volume or folder name instead.
    var displayName: String {
        guard parent == nil else { return name }
        return FileManager.default.displayName(atPath: name)
    }
}
