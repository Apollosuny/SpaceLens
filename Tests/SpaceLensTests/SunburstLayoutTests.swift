import Foundation
import SwiftUI
import Testing
@testable import SpaceLens

@Suite("SunburstLayout")
struct SunburstLayoutTests {
    private let size = CGSize(width: 600, height: 400)
    private let palette = TreemapPalette(colorScheme: .light)

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, fileID: 0, attributes: .directory)
        for child in children { node.addChild(child) }
        return node
    }

    private func file(_ name: String, size: Int64) -> FileNode {
        FileNode(name: name, fileID: 0, attributes: [], category: .documents, ownSize: size, allocatedSize: size)
    }

    private func layout(_ root: FileNode, colorMode: ColorMode = .folder) -> SunburstLayout {
        root.finalizeTree()
        return SunburstLayout(root: root, size: size, sizeMetric: .fileSize, colorMode: colorMode, palette: palette)
    }

    private func point(in layout: SunburstLayout, ring: Int, angle: Double) -> CGPoint {
        let (inner, outer) = layout.geometry.radii(ofRing: ring)
        let radius = Double(inner + outer) / 2
        return CGPoint(x: layout.geometry.center.x + radius * sin(angle), y: layout.geometry.center.y - radius * cos(angle))
    }

    @Test("Ring 1 spans the full circle, split in proportion to size, and children nest inside their parent")
    func anglesProportionalAndNested() throws {
        let root = directory("/scan", [
            directory("big", [file("a", size: 450), file("b", size: 150)]),
            file("c", size: 400)
        ])
        let layout = layout(root)

        let ring1 = layout.rings[0]
        #expect(ring1.count == 2)
        #expect(ring1.first?.startAngle == 0)
        #expect(abs((ring1.last?.endAngle ?? 0) - 2 * .pi) < 1e-9)
        let big = try #require(ring1.first { $0.node.name == "big" })
        #expect(abs((big.endAngle - big.startAngle) - 2 * .pi * 0.6) < 1e-9)

        let ring2 = layout.rings[1]
        #expect(ring2.map(\.node.name) == ["a", "b"])
        #expect(ring2.first?.startAngle == big.startAngle)
        #expect(abs((ring2.last?.endAngle ?? 0) - big.endAngle) < 1e-9)
    }

    @Test("Hit testing maps a point to the segment under it, and the hole and the outside to nothing")
    func hitTesting() throws {
        let root = directory("/scan", [
            directory("big", [file("a", size: 450), file("b", size: 150)]),
            file("c", size: 400)
        ])
        let layout = layout(root)

        // "big" covers 0...0.6 of the circle, "c" the rest; inside big, "a" covers the first three quarters.
        #expect(layout.segment(at: point(in: layout, ring: 1, angle: 0.1))?.node.name == "big")
        #expect(layout.segment(at: point(in: layout, ring: 1, angle: 2 * .pi * 0.9))?.node.name == "c")
        #expect(layout.segment(at: point(in: layout, ring: 2, angle: 2 * .pi * 0.5))?.node.name == "b")
        #expect(layout.segment(at: point(in: layout, ring: 2, angle: 2 * .pi * 0.9)) == nil)
        #expect(layout.segment(at: layout.geometry.center) == nil)
        #expect(layout.isInHole(layout.geometry.center))
        #expect(layout.segment(at: CGPoint(x: 1, y: 1)) == nil)
    }

    @Test("Slivers are grouped into one aggregate segment and nodes beyond the rings map to a drawn ancestor")
    func aggregationAndRepresenting() throws {
        let slivers = (0..<60).map { file("s\($0)", size: 10) }
        let deep = file("deep", size: 5_000)
        let root = directory("/scan", [
            directory("l1", [directory("l2", [directory("l3", [directory("l4", [directory("l5", [deep])])])])]),
            file("huge", size: 100_000)
        ] + slivers)
        let layout = layout(root)

        let aggregates = layout.rings[0].filter(\.isAggregate)
        #expect(aggregates.count == 1)
        #expect(aggregates.first?.node === root)
        #expect(!layout.rings[0].contains { $0.node.name.hasPrefix("s") })

        // Rings go four levels deep, so "deep" (level 6) is represented by l4.
        #expect(layout.segment(representing: deep)?.node.name == "l4")
    }

    @Test("Folder mode gives each top-level folder its own hue; kind mode colors by category")
    func colorModes() throws {
        let root = directory("/scan", [
            directory("one", [file("a", size: 500)]),
            directory("two", [file("b", size: 400)])
        ])
        let byFolder = layout(root, colorMode: .folder)
        let ring1 = byFolder.rings[0]
        #expect(ring1.count == 2)
        #expect(ring1[0].color != ring1[1].color)

        let byKind = SunburstLayout(root: root, size: size, sizeMetric: .fileSize, colorMode: .kind, palette: palette)
        let leaves = byKind.rings[1]
        #expect(leaves.count == 2)
        #expect(leaves.allSatisfy { $0.node.category == .documents })
    }

    @Test("The rasterizer produces a bitmap at the display scale")
    func rasterizes() throws {
        let root = directory("/scan", [file("a", size: 3), file("b", size: 1)])
        let layout = layout(root)
        let image = try #require(SunburstRasterizer(background: palette.background, scale: 2).render(layout))
        #expect(image.width == 1200)
        #expect(image.height == 800)
    }
}
