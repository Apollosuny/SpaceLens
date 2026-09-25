import SwiftUI

struct TreemapView: View {
    let root: FileNode
    let onSelect: (FileNode) -> Void
    let onDrillDown: (FileNode) -> Void
    let sizeMetric: SizeMetric

    @State private var items: [TreemapItem] = []
    /// Incremented whenever `items` is replaced; lets the base canvas skip redraws cheaply.
    @State private var layoutGeneration = 0
    @State private var hoveredItem: TreemapItem?
    @State private var selectedItemID: Int?
    @State private var lastSize: CGSize = .zero
    @State private var layoutTask: Task<Void, Never>?
    @State private var zoomScale: CGFloat = 1.0
    @State private var panOffset: CGPoint = .zero
    @State private var showLabels: Bool = true
    @State private var labelDebounce: Task<Void, Never>?

    /// Delay before re-laying out after a size change, so live window resizing doesn't queue a layout
    /// per frame.
    private static let relayoutDebounce = Duration.milliseconds(80)

    var body: some View {
        VStack(spacing: 0) {
        GeometryReader { geometry in
            ZStack {
                // Base treemap — only redraws when items or selection change
                TreemapBaseCanvas(
                    items: items,
                    layoutGeneration: layoutGeneration,
                    selectedItemID: selectedItemID,
                    zoomScale: zoomScale,
                    panOffset: panOffset,
                    showLabels: showLabels,
                    sizeMetric: sizeMetric
                )
                .equatable()

                // Lightweight hover overlay — redraws only the single highlight rect
                TreemapHoverOverlay(
                    hoveredRect: hoveredItem?.rect,
                    zoomScale: zoomScale,
                    panOffset: panOffset
                )
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let item = hitTestItem(at: screenToContent(location))
                    if item?.id != hoveredItem?.id { hoveredItem = item }
                case .ended:
                    hoveredItem = nil
                }
            }
            .onTapGesture(count: 2) { location in
                if let item = hitTestItem(at: screenToContent(location)), item.node.isDirectory {
                    onDrillDown(item.node)
                }
            }
            .onTapGesture(count: 1) { location in
                if let item = hitTestItem(at: screenToContent(location)) {
                    selectedItemID = item.id
                    onSelect(item.node)
                }
            }
            .contextMenu {
                if let item = hoveredItem {
                    Button("Reveal in Finder") {
                        revealInFinder(node: item.node)
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.node.path, forType: .string)
                    }
                    if item.node.isDirectory {
                        Divider()
                        Button("Drill Down") {
                            onDrillDown(item.node)
                        }
                    }
                }
            }
            .overlay {
                ZoomPanOverlay(
                    onZoom: { factor, center in
                        performZoom(by: factor, centeredAt: center, viewSize: geometry.size)
                    },
                    onPanDelta: { dx, dy in
                        panOffset.x += dx
                        panOffset.y += dy
                        clampPan(viewSize: geometry.size)
                        suppressLabelsDuringInteraction()
                    },
                    onMiddleClick: { location in
                        performZoom(by: 0.5, centeredAt: location, viewSize: geometry.size)
                    }
                )
            }
            .onChange(of: geometry.size) { _, newSize in
                recomputeLayout(size: newSize)
            }
            .onAppear {
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: root.id) {
                zoomScale = 1.0
                panOffset = .zero
                recomputeLayout(size: geometry.size)
            }
            .onChange(of: sizeMetric) {
                recomputeLayout(size: geometry.size)
            }
        }
        .background(.black)

        TreemapStatusBar(node: hoveredItem?.node, sizeMetric: sizeMetric)
        }
        .focusedSceneValue(\.zoomInAction) {
            let center = CGPoint(x: lastSize.width / 2, y: lastSize.height / 2)
            performZoom(by: 0.3, centeredAt: center, viewSize: lastSize)
        }
        .focusedSceneValue(\.zoomOutAction) {
            let center = CGPoint(x: lastSize.width / 2, y: lastSize.height / 2)
            performZoom(by: -0.3, centeredAt: center, viewSize: lastSize)
        }
        .focusedSceneValue(\.resetZoomAction) {
            zoomScale = 1.0
            panOffset = .zero
        }
    }

    private func screenToContent(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - panOffset.x) / zoomScale,
            y: (point.y - panOffset.y) / zoomScale
        )
    }

    private func performZoom(by factor: CGFloat, centeredAt point: CGPoint, viewSize: CGSize) {
        let oldScale = zoomScale
        let newScale = max(1.0, min(oldScale * (1 + factor), 50.0))
        guard newScale != oldScale else { return }

        // Keep the point under cursor fixed in screen space
        let contentPoint = CGPoint(
            x: (point.x - panOffset.x) / oldScale,
            y: (point.y - panOffset.y) / oldScale
        )
        zoomScale = newScale
        panOffset = CGPoint(
            x: point.x - contentPoint.x * newScale,
            y: point.y - contentPoint.y * newScale
        )
        clampPan(viewSize: viewSize)
        suppressLabelsDuringInteraction()
    }

    private func suppressLabelsDuringInteraction() {
        showLabels = false
        labelDebounce?.cancel()
        labelDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            showLabels = true
        }
    }

    private func clampPan(viewSize: CGSize) {
        let contentWidth = viewSize.width * zoomScale
        let contentHeight = viewSize.height * zoomScale
        panOffset.x = min(0, max(viewSize.width - contentWidth, panOffset.x))
        panOffset.y = min(0, max(viewSize.height - contentHeight, panOffset.y))
    }

    private func hitTestItem(at point: CGPoint) -> TreemapItem? {
        for item in items.reversed() {
            if item.rect.contains(point: point) {
                return item
            }
        }
        return nil
    }

    private func recomputeLayout(size: CGSize) {
        guard size.width > 0 && size.height > 0 else { return }
        lastSize = size

        let metric = sizeMetric
        let isInitialLayout = items.isEmpty
        layoutTask?.cancel()
        layoutTask = Task { [root] in
            if !isInitialLayout {
                try? await Task.sleep(for: Self.relayoutDebounce)
            }
            guard !Task.isCancelled else { return }
            let layout = Task.detached(priority: .userInitiated) {
                let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
                return TreemapLayoutEngine().layout(root: root, in: bounds, sizeMetric: metric)
            }
            let newItems = await withTaskCancellationHandler {
                await layout.value
            } onCancel: {
                layout.cancel()
            }
            // A newer layout was requested meanwhile; never let a stale result overwrite it.
            guard !Task.isCancelled else { return }
            items = newItems
            layoutGeneration += 1
            hoveredItem = nil
        }
    }

    private func revealInFinder(node: FileNode) {
        let path = node.path
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}

/// Heavy canvas that renders all treemap items with fills, borders, labels.
/// Extracted as a separate view so SwiftUI skips re-rendering it when only
/// the hovered item changes.
private struct TreemapBaseCanvas: View, Equatable {
    let items: [TreemapItem]
    let layoutGeneration: Int
    let selectedItemID: Int?
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric

    var body: some View {
        Canvas { context, size in
            let renderer = TreemapRenderer(
                items: items,
                selectedItemID: selectedItemID,
                zoomScale: zoomScale,
                panOffset: panOffset,
                showLabels: showLabels,
                sizeMetric: sizeMetric
            )
            renderer.draw(in: &context, size: size)
        }
    }
}

extension TreemapBaseCanvas {
    /// Compares the layout generation instead of the (large, non-Equatable) item array, so hover-driven
    /// body updates of the parent never redraw tens of thousands of rects.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layoutGeneration == rhs.layoutGeneration
            && lhs.selectedItemID == rhs.selectedItemID
            && lhs.zoomScale == rhs.zoomScale
            && lhs.panOffset == rhs.panOffset
            && lhs.showLabels == rhs.showLabels
            && lhs.sizeMetric == rhs.sizeMetric
    }
}

/// Lightweight overlay that draws only the hover highlight rectangle.
/// Re-renders on every hover change but only paints a single translucent rect.
private struct TreemapHoverOverlay: View {
    let hoveredRect: TreemapRect?
    let zoomScale: CGFloat
    let panOffset: CGPoint

    var body: some View {
        Canvas { context, _ in
            guard let rect = hoveredRect else { return }

            let screenRect = CGRect(
                x: panOffset.x + rect.x * zoomScale,
                y: panOffset.y + rect.y * zoomScale,
                width: rect.width * zoomScale,
                height: rect.height * zoomScale
            )
            let path = Path(roundedRect: screenRect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 1)
            context.fill(path, with: .color(.white.opacity(0.25)))
        }
        .allowsHitTesting(false)
    }
}

/// Status bar showing hovered item path and size.
/// Extracted as a separate view so changes only redraw this text, not the canvases.
private struct TreemapStatusBar: View {
    let node: FileNode?
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 0) {
            if let node {
                Text(node.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                    .monospacedDigit()
            } else {
                Text(" ")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
