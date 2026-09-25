import SwiftUI

/// Interactive sunburst of `root`: rings of descendants around a center disk that names the folder.
///
/// Like `TreemapView`, layout and drawing run off the main actor into a bitmap. While a new frame renders
/// after a resize, the old bitmap is scaled uniformly about the center so the circle stays round.
struct SunburstView: View {
    let root: FileNode
    let selection: FileNode?
    let sizeMetric: SizeMetric
    let colorMode: ColorMode
    let canNavigateUp: Bool
    let onSelect: (FileNode) -> Void
    let onOpen: (FileNode) -> Void
    let onNavigateUp: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @State private var frame: SunburstFrame?
    @State private var viewSize: CGSize = .zero
    @State private var hover = SunburstHover()

    private static let resizeDebounce = Duration.milliseconds(80)

    var body: some View {
        let request = SunburstRenderRequest(
            root: ObjectIdentifier(root),
            sizeMetric: sizeMetric,
            colorMode: colorMode,
            colorScheme: colorScheme,
            size: viewSize,
            scale: displayScale
        )

        Color(nsColor: .textBackgroundColor)
            .overlay(alignment: .topLeading) {
                content(for: request)
            }
            .clipped()
            .onGeometryChange(for: CGSize.self, of: \.size) { viewSize = $0 }
            .task(id: request) {
                await render(request)
            }
    }

    @ViewBuilder
    private func content(for request: SunburstRenderRequest) -> some View {
        ZStack(alignment: .topLeading) {
            if let frame {
                let mapping = SunburstScreenMapping(layoutSize: frame.layout.size, viewSize: viewSize)
                let imageRect = mapping.imageRect

                Image(decorative: frame.image, scale: frame.request.scale)
                    .resizable()
                    .frame(width: imageRect.width, height: imageRect.height)
                    .offset(x: imageRect.minX, y: imageRect.minY)

                if let selection, let segment = frame.layout.segment(representing: selection) {
                    SunburstSelectionRing(path: mapping.screenPath(frame.layout.path(for: segment)))
                }

                if frame.request.root == request.root {
                    SunburstInteractionLayer(
                        layout: frame.layout,
                        mapping: mapping,
                        hover: hover,
                        root: root,
                        sizeMetric: sizeMetric,
                        canNavigateUp: canNavigateUp,
                        onSelect: onSelect,
                        onOpen: onOpen,
                        onNavigateUp: onNavigateUp
                    )
                }
            }
        }
        .frame(width: viewSize.width, height: viewSize.height, alignment: .topLeading)
    }

    private func render(_ request: SunburstRenderRequest) async {
        guard request.size.width >= 1, request.size.height >= 1 else { return }

        if let frame, frame.request.hasSameContent(as: request) {
            try? await Task.sleep(for: Self.resizeDebounce)
            guard !Task.isCancelled else { return }
        }

        let root = root
        let work = Task.detached(priority: .userInitiated) { () -> SunburstFrame? in
            let palette = TreemapPalette(colorScheme: request.colorScheme)
            let layout = SunburstLayout(root: root, size: request.size, sizeMetric: request.sizeMetric,
                                        colorMode: request.colorMode, palette: palette)
            let rasterizer = SunburstRasterizer(background: palette.background, scale: request.scale)
            guard !Task.isCancelled, let image = rasterizer.render(layout) else { return nil }
            return SunburstFrame(request: request, layout: layout, image: image)
        }
        let newFrame = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled, let newFrame else { return }
        frame = newFrame
        hover.update(nil)
    }
}

// MARK: - Frames

private struct SunburstRenderRequest: Equatable, Sendable {
    let root: ObjectIdentifier
    let sizeMetric: SizeMetric
    let colorMode: ColorMode
    let colorScheme: ColorScheme
    let size: CGSize
    let scale: CGFloat

    func hasSameContent(as other: Self) -> Bool {
        root == other.root && sizeMetric == other.sizeMetric && colorMode == other.colorMode && colorScheme == other.colorScheme
    }
}

/// A layout and its rendered bitmap. The image is immutable once made, so sharing it across actors is safe.
private struct SunburstFrame: @unchecked Sendable {
    let request: SunburstRenderRequest
    let layout: SunburstLayout
    let image: CGImage
}

/// Maps between the view and a layout rendered for another size: uniform scale about the centers.
private struct SunburstScreenMapping {
    let layoutSize: CGSize
    let viewSize: CGSize

    private var scale: CGFloat {
        let old = min(layoutSize.width, layoutSize.height)
        return old > 0 ? min(viewSize.width, viewSize.height) / old : 1
    }

    var imageRect: CGRect {
        let size = CGSize(width: layoutSize.width * scale, height: layoutSize.height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    var transform: CGAffineTransform {
        let rect = imageRect
        return CGAffineTransform(translationX: rect.minX, y: rect.minY).scaledBy(x: scale, y: scale)
    }

    func layoutPoint(for screenPoint: CGPoint) -> CGPoint {
        screenPoint.applying(transform.inverted())
    }

    func screenPath(_ path: CGPath) -> Path {
        Path(path).applying(transform)
    }

    var holeCenter: CGPoint { CGPoint(x: viewSize.width / 2, y: viewSize.height / 2) }
}

// MARK: - Overlays

@Observable
@MainActor
private final class SunburstHover {
    private(set) var segment: SunburstSegment?

    func update(_ newSegment: SunburstSegment?) {
        if newSegment?.id != segment?.id { segment = newSegment }
    }
}

private struct SunburstSelectionRing: View {
    let path: Path

    var body: some View {
        ZStack {
            path.stroke(.primary, lineWidth: 3)
            path.stroke(.white, lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Hover highlight, tooltip, center label, clicks and the context menu.
private struct SunburstInteractionLayer: View {
    let layout: SunburstLayout
    let mapping: SunburstScreenMapping
    let hover: SunburstHover
    let root: FileNode
    let sizeMetric: SizeMetric
    let canNavigateUp: Bool
    let onSelect: (FileNode) -> Void
    let onOpen: (FileNode) -> Void
    let onNavigateUp: () -> Void

    @State private var pointer: CGPoint = .zero

    var body: some View {
        let holeDiameter = layout.geometry.holeRadius * 2 * mapping.imageRect.width / max(layout.size.width, 1)

        ZStack(alignment: .topLeading) {
            SunburstCenterLabel(root: root, sizeMetric: sizeMetric, canNavigateUp: canNavigateUp)
                .frame(width: holeDiameter * 0.8, height: holeDiameter * 0.8)
                .position(mapping.holeCenter)
                .allowsHitTesting(false)

            if let segment = hover.segment {
                let path = mapping.screenPath(layout.path(for: segment))
                path.fill(.white.opacity(0.25))
                path.stroke(.white.opacity(0.85), lineWidth: 1.5)

                TreemapTooltip(node: segment.node, rootSize: root.size(for: sizeMetric), sizeMetric: sizeMetric)
                    .offset(tooltipOffset())
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                pointer = location
                hover.update(layout.segment(at: mapping.layoutPoint(for: location)))
            case .ended:
                hover.update(nil)
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            let point = mapping.layoutPoint(for: value.location)
            if layout.isInHole(point) {
                onNavigateUp()
                return
            }
            guard let segment = layout.segment(at: point) else { return }
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 && segment.node.isDirectory {
                onOpen(segment.node)
            } else {
                onSelect(segment.node)
            }
        })
        .contextMenu {
            if let node = hover.segment?.node {
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

    /// Next to the pointer, flipped to stay inside the view.
    private func tooltipOffset() -> CGSize {
        let viewSize = mapping.viewSize
        var x = pointer.x + 16
        if x + TreemapTooltip.width > viewSize.width - 8 { x = pointer.x - 16 - TreemapTooltip.width }
        var y = pointer.y + 16
        if y + TreemapTooltip.estimatedHeight > viewSize.height - 8 { y = pointer.y - 16 - TreemapTooltip.estimatedHeight }
        return CGSize(width: max(8, x), height: max(8, y))
    }
}

/// Folder name, size and a hint in the hole of the sunburst.
private struct SunburstCenterLabel: View {
    let root: FileNode
    let sizeMetric: SizeMetric
    let canNavigateUp: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(root.displayName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(ByteFormatter.string(from: root.size(for: sizeMetric)))
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(canNavigateUp ? "Click here to go up" : "Double-click a segment to open it")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .minimumScaleFactor(0.5)
    }
}
