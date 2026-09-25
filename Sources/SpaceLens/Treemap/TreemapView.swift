import SwiftUI

/// Interactive treemap of `root`.
///
/// Layout and drawing run off the main actor into a bitmap (`TreemapFrame`). While a newer frame is being
/// produced — during window or column resizes, zooming and panning — the last bitmap is stretched and
/// offset to stand in, so the main thread only composites one image per animation frame.
struct TreemapView: View {
    let root: FileNode
    let selection: FileNode?
    let sizeMetric: SizeMetric
    let colorMode: ColorMode
    let viewport: TreemapViewport
    let onSelect: (FileNode) -> Void
    let onOpen: (FileNode) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var frame: TreemapFrame?
    @State private var viewSize: CGSize = .zero
    @State private var hover = TreemapHover()

    /// Delay before re-rendering after a size change, so live resizing doesn't render every frame.
    private static let resizeDebounce = Duration.milliseconds(80)
    /// Delay before re-rendering sharply after zooming or panning stops.
    private static let transformDebounce = Duration.milliseconds(120)

    var body: some View {
        let request = TreemapRenderRequest(
            root: ObjectIdentifier(root),
            sizeMetric: sizeMetric,
            colorMode: colorMode,
            colorScheme: colorScheme,
            size: viewSize,
            transform: viewport.transform,
            scale: displayScale
        )

        // The content lives in an overlay so it never feeds back into the view's own size: the bitmap is
        // rounded up to whole pixels and, while stretched, larger than the view.
        Color(nsColor: .textBackgroundColor)
            .overlay(alignment: .topLeading) {
                content(for: request)
            }
            .clipped()
            .overlay {
                ZoomPanOverlay(
                    onZoom: { factor, center in viewport.zoom(by: factor, around: center) },
                    onPanDelta: { dx, dy in viewport.pan(dx: dx, dy: dy) },
                    onMiddleClick: { location in viewport.zoom(by: -0.5, around: location) }
                )
            }
            .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                viewSize = newSize
                viewport.viewSize = newSize
            }
            .task(id: request) {
                await render(request)
            }
    }

    @ViewBuilder
    private func content(for request: TreemapRenderRequest) -> some View {
        ZStack(alignment: .topLeading) {
            if let frame {
                let mapping = TreemapScreenMapping(frame: frame, viewSize: viewSize, transform: viewport.transform)
                let imageRect = mapping.imageRect

                Image(decorative: frame.image, scale: frame.request.scale)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .offset(x: imageRect.minX, y: imageRect.minY)

                TreemapSelectionRing(rect: selectionRect(in: frame, mapping: mapping))

                // Until the frame for a new root arrives, the previous one is only a placeholder.
                if frame.request.root == request.root {
                    TreemapInteractionLayer(
                        layout: frame.layout,
                        mapping: mapping,
                        hover: hover,
                        rootSize: root.size(for: sizeMetric),
                        sizeMetric: sizeMetric,
                        onSelect: onSelect,
                        onOpen: onOpen
                    )
                }
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
    }

    private func selectionRect(in frame: TreemapFrame, mapping: TreemapScreenMapping) -> CGRect? {
        guard let selection, let item = frame.layout.item(representing: selection), !frame.layout.isRoot(item) else { return nil }
        return mapping.screenRect(for: item.rect)
    }

    private func render(_ request: TreemapRenderRequest) async {
        guard request.size.width >= 1, request.size.height >= 1 else { return }

        let reusableLayout = frame.flatMap { $0.request.hasSameLayout(as: request) ? $0.layout : nil }
        if let frame, frame.request.hasSameContent(as: request) {
            // The current image can stand in (stretched or offset) while the input keeps changing.
            try? await Task.sleep(for: reusableLayout == nil ? Self.resizeDebounce : Self.transformDebounce)
            guard !Task.isCancelled else { return }
        }

        let root = root
        let work = Task.detached(priority: .userInitiated) { () -> TreemapFrame? in
            let layout = reusableLayout ?? TreemapLayoutEngine(colorScheme: request.colorScheme, colorMode: request.colorMode)
                .makeLayout(root: root, size: request.size, sizeMetric: request.sizeMetric)
            let rasterizer = TreemapRasterizer(colorScheme: request.colorScheme, sizeMetric: request.sizeMetric, scale: request.scale)
            guard !Task.isCancelled, let image = rasterizer.render(layout, transform: request.transform) else { return nil }
            return TreemapFrame(request: request, layout: layout, image: image)
        }
        let newFrame = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        // A newer request superseded this one; never let a stale result overwrite it.
        guard !Task.isCancelled, let newFrame else { return }
        frame = newFrame
        if reusableLayout == nil { hover.update(nil) }
    }
}

// MARK: - Frames

/// Everything a rendered frame depends on.
private struct TreemapRenderRequest: Equatable, Sendable {
    let root: ObjectIdentifier
    let sizeMetric: SizeMetric
    let colorMode: ColorMode
    let colorScheme: ColorScheme
    let size: CGSize
    let transform: TreemapTransform
    let scale: CGFloat

    /// Same tree, metric and colors: an older frame is a fair stand-in while this one renders.
    func hasSameContent(as other: Self) -> Bool {
        root == other.root && sizeMetric == other.sizeMetric && colorMode == other.colorMode && colorScheme == other.colorScheme
    }

    /// Only the transform or scale differ, so the item layout can be reused.
    func hasSameLayout(as other: Self) -> Bool {
        hasSameContent(as: other) && size == other.size
    }
}

/// A layout and its rendered bitmap. The image is immutable once made, so sharing it across actors is safe.
private struct TreemapFrame: @unchecked Sendable {
    let request: TreemapRenderRequest
    let layout: TreemapLayout
    let image: CGImage
}

/// Maps between the view and the layout while the displayed frame may lag behind the current view size
/// and transform: the frame's image is scaled by the zoom change, then stretched to the view size.
private struct TreemapScreenMapping {
    let frame: TreemapFrame
    let viewSize: CGSize
    let transform: TreemapTransform

    private var stretch: CGSize {
        let size = frame.layout.size
        return CGSize(width: viewSize.width / size.width, height: viewSize.height / size.height)
    }

    var imageRect: CGRect {
        let rendered = frame.request.transform
        let zoomChange = transform.zoom / rendered.zoom
        let imageSize = CGSize(
            width: CGFloat(frame.image.width) / frame.request.scale,
            height: CGFloat(frame.image.height) / frame.request.scale
        )
        return CGRect(
            x: (transform.pan.x - rendered.pan.x * zoomChange) * stretch.width,
            y: (transform.pan.y - rendered.pan.y * zoomChange) * stretch.height,
            width: imageSize.width * zoomChange * stretch.width,
            height: imageSize.height * zoomChange * stretch.height
        )
    }

    func screenRect(for rect: TreemapRect) -> CGRect {
        let layoutRect = transform.screenRect(for: rect)
        return CGRect(
            x: layoutRect.minX * stretch.width,
            y: layoutRect.minY * stretch.height,
            width: layoutRect.width * stretch.width,
            height: layoutRect.height * stretch.height
        )
    }

    func contentPoint(for screenPoint: CGPoint) -> CGPoint {
        transform.contentPoint(for: CGPoint(x: screenPoint.x / stretch.width, y: screenPoint.y / stretch.height))
    }
}

// MARK: - Overlays

/// The hovered item, kept in its own observable so hovering re-renders only the interaction layer.
@Observable
@MainActor
private final class TreemapHover {
    private(set) var item: TreemapItem?

    func update(_ newItem: TreemapItem?) {
        if newItem?.id != item?.id { item = newItem }
    }
}

private struct TreemapSelectionRing: View {
    let rect: CGRect?

    var body: some View {
        Canvas { context, _ in
            guard let rect else { return }
            let ring = rect.insetBy(dx: 0.75, dy: 0.75)
            // An outer ring in the label color plus a white inner ring reads on every fill in both appearances.
            context.stroke(Path(roundedRect: ring, cornerRadius: 4), with: .color(.primary), lineWidth: 3)
            context.stroke(Path(roundedRect: ring.insetBy(dx: 1.5, dy: 1.5), cornerRadius: 3), with: .color(.white), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

/// Hover highlight, tooltip, clicks and the context menu.
private struct TreemapInteractionLayer: View {
    let layout: TreemapLayout
    let mapping: TreemapScreenMapping
    let hover: TreemapHover
    let rootSize: Int64
    let sizeMetric: SizeMetric
    let onSelect: (FileNode) -> Void
    let onOpen: (FileNode) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let item = hover.item {
                let rect = mapping.screenRect(for: item.rect)
                Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4)
                    .fill(.white.opacity(0.2))
                Path(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4)
                    .stroke(.white.opacity(0.8), lineWidth: 1.5)

                TreemapTooltip(node: item.node, rootSize: rootSize, sizeMetric: sizeMetric)
                    .offset(tooltipOffset(for: rect))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                hover.update(layout.item(at: mapping.contentPoint(for: location)))
            case .ended:
                hover.update(nil)
            }
        }
        // One tap gesture reading the click count: pairing `count: 2` with `count: 1` would hold every
        // single click until the double-click interval has passed.
        .gesture(SpatialTapGesture().onEnded { value in
            guard let item = layout.item(at: mapping.contentPoint(for: value.location)) else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 && item.node.isDirectory {
                onOpen(item.node)
            } else {
                onSelect(item.node)
            }
        })
        .contextMenu {
            if let node = hover.item?.node {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                }
                if node.isDirectory {
                    Divider()
                    Button("Open") { onOpen(node) }
                }
            }
        }
    }

    /// Places the tooltip just inside the hovered rect's top-left corner, flipped above it near the bottom
    /// edge and kept inside the view horizontally.
    private func tooltipOffset(for rect: CGRect) -> CGSize {
        let viewSize = mapping.viewSize
        let below = max(0, rect.minY) + min(rect.height, 40) + 6
        let y = below + TreemapTooltip.estimatedHeight > viewSize.height
            ? max(0, rect.minY - TreemapTooltip.estimatedHeight - 6)
            : below
        let x = min(max(8, rect.minX + 12), viewSize.width - TreemapTooltip.width - 8)
        return CGSize(width: max(0, x), height: y)
    }
}

/// Glass card describing the hovered item.
struct TreemapTooltip: View {
    static let width: CGFloat = 240
    static let estimatedHeight: CGFloat = 76

    let node: FileNode
    let rootSize: Int64
    let sizeMetric: SizeMetric

    var body: some View {
        let size = node.size(for: sizeMetric)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: node.isDirectory ? "folder.fill" : node.category.sfSymbol)
                    .foregroundStyle(node.category.color)
                Text(node.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(node.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            HStack {
                Text(ByteFormatter.string(from: size))
                    .fontWeight(.semibold)
                Spacer()
                if rootSize > 0 {
                    Text(Double(size) / Double(rootSize), format: .percent.precision(.fractionLength(1)))
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.width, alignment: .leading)
        .glassSurface(in: .rect(cornerRadius: 11))
    }
}
