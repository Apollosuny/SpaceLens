import SwiftUI

/// One arc of the sunburst. Angles are in radians, clockwise from 12 o'clock.
struct SunburstSegment: Identifiable, Sendable {
    let id: Int
    let node: FileNode
    /// 1 for the view root's children, increasing outward.
    let ring: Int
    let startAngle: Double
    let endAngle: Double
    let color: CGColor
    /// Stands for the node's children too narrow to draw individually.
    var isAggregate = false
}

/// Radii of the rings for a given view size: a hole in the middle for the center label, then equal rings.
struct SunburstGeometry: Equatable, Sendable {
    let center: CGPoint
    let holeRadius: CGFloat
    let ringWidth: CGFloat

    init(size: CGSize, ringCount: Int) {
        let radius = max(0, min(size.width, size.height) / 2 - 16)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        holeRadius = radius * 0.32
        ringWidth = (radius - holeRadius) / CGFloat(max(1, ringCount))
    }

    func radii(ofRing ring: Int) -> (inner: CGFloat, outer: CGFloat) {
        let inner = holeRadius + CGFloat(ring - 1) * ringWidth
        return (inner, inner + ringWidth)
    }
}

/// A laid-out sunburst of `root`, with lookup by point and by node.
struct SunburstLayout: Sendable {
    static let ringCount = 4
    /// Arcs narrower than this (radians, about half a degree) are grouped into one aggregate arc.
    static let minAngle = 0.009

    let size: CGSize
    let geometry: SunburstGeometry
    /// Segments per ring (index 0 is ring 1), each sorted by angle.
    let rings: [[SunburstSegment]]
    private let locationByNode: [ObjectIdentifier: (ring: Int, index: Int)]

    init(root: FileNode, size: CGSize, sizeMetric: SizeMetric, colorMode: ColorMode, palette: TreemapPalette) {
        self.size = size
        geometry = SunburstGeometry(size: size, ringCount: Self.ringCount)

        var rings = Array(repeating: [SunburstSegment](), count: Self.ringCount)
        var nextID = 0

        func addChildren(of node: FileNode, ring: Int, start: Double, span: Double, branch: Int?) {
            let total = Double(node.size(for: sizeMetric))
            guard ring <= Self.ringCount, total > 0, !Task.isCancelled else { return }
            var angle = start
            for (index, child) in TreemapLayoutEngine.orderedChildren(of: node, sizeMetric: sizeMetric).enumerated() {
                let childSpan = span * Double(child.size(for: sizeMetric)) / total
                let childBranch = ring == 1 ? index : branch
                if childSpan < Self.minAngle {
                    // Children are sorted by size: the rest are all narrower. Group what is left of the parent.
                    let rest = start + span - angle
                    if rest >= Self.minAngle {
                        rings[ring - 1].append(SunburstSegment(
                            id: nextID, node: node, ring: ring, startAngle: angle, endAngle: start + span,
                            color: palette.aggregate(branch: ring == 1 ? index : branch, mode: colorMode), isAggregate: true
                        ))
                        nextID += 1
                    }
                    return
                }
                rings[ring - 1].append(SunburstSegment(
                    id: nextID, node: child, ring: ring, startAngle: angle, endAngle: angle + childSpan,
                    color: palette.fill(for: child, branch: childBranch, depth: ring, sibling: index, mode: colorMode)
                ))
                nextID += 1
                if child.isDirectory {
                    addChildren(of: child, ring: ring + 1, start: angle, span: childSpan, branch: childBranch)
                }
                angle += childSpan
            }
        }
        addChildren(of: root, ring: 1, start: 0, span: 2 * .pi, branch: nil)

        // Children are appended depth-first, so a ring's segments are already in angle order.
        self.rings = rings
        var locationByNode: [ObjectIdentifier: (ring: Int, index: Int)] = [:]
        for (ringIndex, segments) in rings.enumerated() {
            for (index, segment) in segments.enumerated() where !segment.isAggregate {
                locationByNode[ObjectIdentifier(segment.node)] = (ringIndex, index)
            }
        }
        self.locationByNode = locationByNode
    }

    func isInHole(_ point: CGPoint) -> Bool {
        hypot(point.x - geometry.center.x, point.y - geometry.center.y) < geometry.holeRadius
    }

    func segment(at point: CGPoint) -> SunburstSegment? {
        let dx = point.x - geometry.center.x
        let dy = point.y - geometry.center.y
        let radius = hypot(dx, dy)
        guard radius >= geometry.holeRadius, geometry.ringWidth > 0 else { return nil }
        let ring = Int((radius - geometry.holeRadius) / geometry.ringWidth) + 1
        guard ring <= Self.ringCount else { return nil }

        var angle = atan2(Double(dx), Double(-dy))
        if angle < 0 { angle += 2 * .pi }
        let segments = rings[ring - 1]
        // Binary search for the last segment starting at or before `angle`.
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].startAngle <= angle { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        let candidate = segments[low - 1]
        return angle < candidate.endAngle ? candidate : nil
    }

    /// The segment drawn for `node` or, when it is not drawn, for its nearest drawn ancestor.
    func segment(representing node: FileNode) -> SunburstSegment? {
        var candidate: FileNode? = node
        while let current = candidate {
            if let location = locationByNode[ObjectIdentifier(current)] { return rings[location.ring][location.index] }
            candidate = current.parent
        }
        return nil
    }

    /// The annular sector of `segment` in layout coordinates.
    func path(for segment: SunburstSegment) -> CGPath {
        let (inner, outer) = geometry.radii(ofRing: segment.ring)
        // Angles are measured from 12 o'clock; Core Graphics measures from 3 o'clock. With the y axis
        // pointing down, increasing angles run clockwise on screen.
        let start = CGFloat(segment.startAngle) - .pi / 2
        let end = CGFloat(segment.endAngle) - .pi / 2
        let path = CGMutablePath()
        path.addArc(center: geometry.center, radius: outer, startAngle: start, endAngle: end, clockwise: false)
        path.addArc(center: geometry.center, radius: inner, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// Draws a sunburst into a bitmap off the main actor.
struct SunburstRasterizer: Sendable {
    let background: CGColor
    let scale: CGFloat

    func render(_ layout: SunburstLayout) -> CGImage? {
        let pixelWidth = Int((layout.size.width * scale).rounded(.up))
        let pixelHeight = Int((layout.size.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.setFillColor(background)
        context.fill(CGRect(origin: .zero, size: layout.size))

        // One fill per color, then one hairline in the background color to separate neighbouring arcs.
        var fills: [CGColor: CGMutablePath] = [:]
        let outlines = CGMutablePath()
        for segments in layout.rings {
            for segment in segments {
                if Task.isCancelled { return nil }
                let path = layout.path(for: segment)
                let fill = fills[segment.color] ?? {
                    let fill = CGMutablePath()
                    fills[segment.color] = fill
                    return fill
                }()
                fill.addPath(path)
                outlines.addPath(path)
            }
        }
        for (color, path) in fills {
            context.addPath(path)
            context.setFillColor(color)
            context.fillPath()
        }
        context.addPath(outlines)
        context.setStrokeColor(background)
        context.setLineWidth(1)
        context.strokePath()
        return context.makeImage()
    }
}
