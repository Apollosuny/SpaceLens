import SwiftUI

struct TreemapRenderer {
    let items: [TreemapItem]
    let selectedItemID: Int?
    let zoomScale: CGFloat
    let panOffset: CGPoint
    let showLabels: Bool
    let sizeMetric: SizeMetric

    /// Rects smaller than this (in points) get no border or rounded corners: invisible at that size,
    /// and they dominate the item count.
    private static let minDetailedSide: CGFloat = 3

    /// Draws all items with one fill per (depth, color) and one stroke per depth instead of one draw call
    /// per item. Items are laid out so that a child lies inside its parent and siblings never overlap, so
    /// painting depth by depth preserves the visual stacking of drawing item by item.
    func draw(in context: inout GraphicsContext, size: CGSize) {
        let viewport = CGRect(origin: .zero, size: size)

        var layers: [DepthLayer] = []
        var selectedRect: CGRect?

        for item in items {
            let screenRect = screenRect(for: item)
            guard screenRect.intersects(viewport) else { continue }

            while layers.count <= item.depth { layers.append(DepthLayer()) }
            let isDetailed = screenRect.width >= Self.minDetailedSide && screenRect.height >= Self.minDetailedSide
            let drawRect = isDetailed ? screenRect.insetBy(dx: 0.5, dy: 0.5) : screenRect
            layers[item.depth].addFill(drawRect, color: item.color, rounded: isDetailed)
            if isDetailed {
                layers[item.depth].border.addRoundedRect(in: drawRect, cornerSize: CGSize(width: 1, height: 1))
            }
            // A container's label would be painted over by its children, so skip the costly text layout.
            if showLabels && !item.hasChildren && screenRect.width > 60 && screenRect.height > 16 {
                layers[item.depth].labels.append((item, screenRect))
            }
            if item.id == selectedItemID {
                selectedRect = screenRect
            }
        }

        for layer in layers {
            for (color, path) in layer.fills {
                context.fill(path, with: .color(Color(cgColor: color)))
            }
            context.stroke(layer.border, with: .color(.black.opacity(0.3)), lineWidth: 0.5)
            for (item, rect) in layer.labels {
                drawLabels(for: item, in: rect, context: &context)
            }
        }

        if let selectedRect {
            context.stroke(Path(selectedRect.insetBy(dx: 1, dy: 1)), with: .color(.white), lineWidth: 2)
        }
    }

    private func screenRect(for item: TreemapItem) -> CGRect {
        CGRect(
            x: panOffset.x + item.rect.x * zoomScale,
            y: panOffset.y + item.rect.y * zoomScale,
            width: item.rect.width * zoomScale,
            height: item.rect.height * zoomScale
        )
    }

    /// Name label (10pt regardless of zoom) plus a size label for larger rects.
    private func drawLabels(for item: TreemapItem, in screenRect: CGRect, context: inout GraphicsContext) {
        let labelRect = CGRect(
            x: screenRect.minX + 3,
            y: screenRect.minY + 2,
            width: screenRect.width - 6,
            height: min(screenRect.height - 4, 16)
        )
        context.draw(
            Text(item.node.name).font(.system(size: 10)).foregroundColor(.white),
            in: labelRect
        )

        guard screenRect.width > 80 && screenRect.height > 32 else { return }
        let sizeRect = CGRect(x: screenRect.minX + 3, y: screenRect.minY + 16, width: screenRect.width - 6, height: 14)
        context.draw(
            Text(ByteFormatter.string(from: item.node.size(for: sizeMetric)))
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.7)),
            in: sizeRect
        )
    }
}

private struct DepthLayer {
    /// Keyed by color; `TreemapItem.color` takes one of a few values per depth (one per category).
    var fills: [CGColor: Path] = [:]
    var border = Path()
    var labels: [(TreemapItem, CGRect)] = []

    mutating func addFill(_ rect: CGRect, color: CGColor, rounded: Bool) {
        if rounded {
            fills[color, default: Path()].addRoundedRect(in: rect, cornerSize: CGSize(width: 1, height: 1))
        } else {
            fills[color, default: Path()].addRect(rect)
        }
    }
}
