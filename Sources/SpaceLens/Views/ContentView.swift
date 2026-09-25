import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var coordinator: ScanCoordinator?
    @AppStorage("includeHiddenFiles") private var includeHiddenFiles = true
    @FocusedValue(\.zoomInAction) private var zoomIn
    @FocusedValue(\.zoomOutAction) private var zoomOut
    @FocusedValue(\.resetZoomAction) private var resetZoom

    var body: some View {
        @Bindable var state = appState

        NavigationSplitView {
            if let root = appState.rootNode {
                DirectoryTreeView(root: root, selectedNode: $state.selectedNode, sizeMetric: appState.sizeMetric)
                    .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 400)
            } else {
                Text("No data")
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity)
            }
        } detail: {
            ZStack {
                switch appState.scanStatus {
                case .idle:
                    WelcomeView(
                        history: appState.history,
                        includeHiddenFiles: $includeHiddenFiles,
                        onVolumeSelected: { path in
                            coordinator?.startScan(path: path, options: ScanOptions(includeHiddenFiles: includeHiddenFiles))
                        },
                        onClearHistory: { coordinator?.clearHistory() }
                    )
                    .transition(.opacity)

                case let .scanning(progress):
                    ScanProgressView(progress: progress) {
                        coordinator?.cancel()
                        appState.scanStatus = .idle
                    }

                case .completed:
                    if let treemapRoot = appState.treemapRoot {
                        VStack(spacing: 0) {
                            if let report = appState.lastReport, report.inaccessibleCount > 0 {
                                InaccessibleFoldersBanner(report: report)
                            }

                            // Breadcrumb bar
                            BreadcrumbBar(
                                breadcrumbs: appState.breadcrumbs,
                                onNavigate: { node in
                                    appState.navigateTo(breadcrumb: node)
                                }
                            )

                            // Treemap
                            TreemapView(
                                root: treemapRoot,
                                onSelect: { node in
                                    appState.selectedNode = node
                                },
                                onDrillDown: { node in
                                    appState.drillDown(to: node)
                                },
                                sizeMetric: appState.sizeMetric
                            )
                        }
                    }

                case let .error(message):
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Scan Error")
                            .font(.title2.bold())
                        Text(message)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            appState.reset()
                        }
                    }
                }
            }
        }
        .inspector(isPresented: $state.showInspector) {
            if let selected = appState.selectedNode {
                DetailPanelView(node: selected)
                    .inspectorColumnWidth(min: 250, ideal: 300, max: 400)
            } else {
                Text("Select an item to view details")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Button("Full Rescan") {
                        coordinator?.rescan(mode: .full)
                    }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                } primaryAction: {
                    coordinator?.rescan(mode: .automatic)
                }
                .help("Rescan, re-reading only folders changed since the last scan")
                .disabled(appState.lastReport == nil || appState.isScanning)

                Button {
                    selectAndScan()
                } label: {
                    Label("Scan Drive", systemImage: "internaldrive.fill")
                }

                SizeMetricPicker(sizeMetric: $state.sizeMetric) {
                    if appState.scanStatus == .idle, appState.rootNode != nil {
                        appState.scanStatus = .completed
                    }
                }

                Button {
                    zoomIn?()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .disabled(zoomIn == nil)

                Button {
                    zoomOut?()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .disabled(zoomOut == nil)

                Button {
                    resetZoom?()
                } label: {
                    Label("Reset Zoom", systemImage: "1.magnifyingglass")
                }
                .disabled(resetZoom == nil)

                Button {
                    appState.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }

            ToolbarItem(placement: .navigation) {
                if appState.treemapRoot?.parent != nil {
                    Button {
                        appState.navigateUp()
                    } label: {
                        Label("Back", systemImage: "chevron.left")
                    }
                }
            }
        }
        .onAppear {
            if coordinator == nil {
                coordinator = ScanCoordinator(appState: appState)
            }
        }
        .focusedSceneValue(\.scanAction, {
            selectAndScan()
        })
    }

    private func selectAndScan() {
        coordinator?.cancel()
        appState.scanStatus = .idle
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
                .font(.callout)
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
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
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

// MARK: - Size Metric Picker

struct SizeMetricPicker: View {
    @Binding var sizeMetric: SizeMetric
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SizeMetric.allCases, id: \.self) { metric in
                Button {
                    sizeMetric = metric
                    onTap()
                } label: {
                    Text(metric.rawValue)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .background(sizeMetric == metric ? Color.accentColor.opacity(0.2) : Color.clear)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
    }
}

// MARK: - Breadcrumb Bar

struct BreadcrumbBar: View {
    let breadcrumbs: [FileNode]
    let onNavigate: (FileNode) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(breadcrumbs.enumerated()), id: \.element.id) { index, node in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button {
                        onNavigate(node)
                    } label: {
                        Text(node.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(index == breadcrumbs.count - 1 ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

// MARK: - Focused Value for Menu Commands

struct ScanActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomInActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ZoomOutActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct ResetZoomActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var scanAction: (() -> Void)? {
        get { self[ScanActionKey.self] }
        set { self[ScanActionKey.self] = newValue }
    }

    var zoomInAction: (() -> Void)? {
        get { self[ZoomInActionKey.self] }
        set { self[ZoomInActionKey.self] = newValue }
    }

    var zoomOutAction: (() -> Void)? {
        get { self[ZoomOutActionKey.self] }
        set { self[ZoomOutActionKey.self] = newValue }
    }

    var resetZoomAction: (() -> Void)? {
        get { self[ResetZoomActionKey.self] }
        set { self[ResetZoomActionKey.self] = newValue }
    }
}
