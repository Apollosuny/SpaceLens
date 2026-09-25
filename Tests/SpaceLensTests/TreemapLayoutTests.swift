import Foundation
import Testing
@testable import SpaceLens

@Suite("TreemapLayout")
struct TreemapLayoutTests {
    private let bounds = TreemapRect(x: 0, y: 0, width: 800, height: 600)

    private func directory(_ name: String, _ children: [FileNode]) -> FileNode {
        let node = FileNode(name: name, fileID: 0, attributes: .directory)
        for child in children { node.addChild(child) }
        return node
    }

    private func file(_ name: String, size: Int64) -> FileNode {
        FileNode(name: name, fileID: 0, attributes: [], category: .documents, ownSize: size, allocatedSize: size)
    }

    private func layout(_ root: FileNode) -> [TreemapItem] {
        root.finalizeTree()
        return TreemapLayoutEngine().layout(root: root, in: bounds)
    }

    @Test("A large folder gets a header bar and its children stay below it, inside the frame padding")
    func largeFolderReservesHeader() throws {
        let root = directory("/scan", [
            directory("big", [file("a", size: 600), file("b", size: 300)]),
            file("c", size: 100)
        ])
        let items = layout(root)

        let rootItem = try #require(items.first { $0.node === root })
        #expect(!rootItem.hasHeader)

        let big = try #require(items.first { $0.node.name == "big" })
        #expect(big.hasHeader)
        let content = TreemapLayoutEngine.contentBounds(ofHeadedFrame: big.rect)
        let children = items.filter { $0.node.parent === big.node }
        #expect(children.count == 2)
        for child in children {
            #expect(child.rect.y >= big.rect.y + TreemapLayoutEngine.headerHeight - 1e-9)
            #expect(child.rect.x >= content.x - 1e-9)
            #expect(child.rect.x + child.rect.width <= content.x + content.width + 1e-9)
            #expect(child.rect.y + child.rect.height <= content.y + content.height + 1e-9)
        }
        let childArea = children.reduce(0) { $0 + $1.rect.area }
        #expect(abs(childArea - content.area) < 1e-6)
    }

    @Test("A folder smaller than the header threshold is not headed and its children fill it")
    func smallFolderHasNoHeader() throws {
        let root = directory("/scan", [
            file("huge", size: 1_000_000),
            directory("tiny", [file("x", size: 1500), file("y", size: 1500)])
        ])
        let items = layout(root)

        let tiny = try #require(items.first { $0.node.name == "tiny" })
        #expect(tiny.rect.width < TreemapLayoutEngine.minHeaderFrameSize.width
            || tiny.rect.height < TreemapLayoutEngine.minHeaderFrameSize.height)
        #expect(!tiny.hasHeader)
        let childArea = items.filter { $0.node.parent === tiny.node }.reduce(0) { $0 + $1.rect.area }
        #expect(abs(childArea - tiny.rect.area) < 1e-6)
    }

    @Test("Leaf colors follow the requested appearance")
    func paletteFollowsColorScheme() {
        let light = TreemapPalette(colorScheme: .light)
        let dark = TreemapPalette(colorScheme: .dark)
        #expect(light.background != dark.background)
        #expect(light.color(for: .documents) != dark.color(for: .documents))
    }

    @Test("Hit testing returns the deepest item, the folder on its header, and nil outside")
    func hitTesting() throws {
        let root = directory("/scan", [
            directory("big", [file("a", size: 600), file("b", size: 300)]),
            file("c", size: 100)
        ])
        root.finalizeTree()
        let layout = TreemapLayoutEngine().makeLayout(root: root, size: CGSize(width: 800, height: 600), sizeMetric: .fileSize)

        let big = try #require(layout.items.first { $0.node.name == "big" })
        let a = try #require(layout.items.first { $0.node.name == "a" })
        let c = try #require(layout.items.first { $0.node.name == "c" })

        #expect(layout.item(at: CGPoint(x: a.rect.x + a.rect.width / 2, y: a.rect.y + a.rect.height / 2))?.node.name == "a")
        #expect(layout.item(at: CGPoint(x: c.rect.x + c.rect.width / 2, y: c.rect.y + c.rect.height / 2))?.node.name == "c")
        #expect(layout.item(at: CGPoint(x: big.rect.x + big.rect.width / 2, y: big.rect.y + 4))?.node.name == "big")
        #expect(layout.item(at: CGPoint(x: 900, y: 10)) == nil)
    }

    @Test("A node too small to draw is represented by its nearest drawn ancestor")
    func representingUndrawnNode() throws {
        let speck = file("speck", size: 1)
        let root = directory("/scan", [
            directory("big", [file("a", size: 1_000_000), speck]),
            file("c", size: 100_000)
        ])
        root.finalizeTree()
        let layout = TreemapLayoutEngine().makeLayout(root: root, size: CGSize(width: 800, height: 600), sizeMetric: .fileSize)

        #expect(!layout.items.contains { $0.node === speck })
        #expect(layout.item(representing: speck)?.node.name == "big")
        #expect(layout.item(representing: FileNode(name: "elsewhere", fileID: 0, attributes: [])) == nil)
    }

    @Test("The rasterizer renders at the layout size times the display scale")
    func rasterizesAtScale() throws {
        let root = directory("/scan", [directory("big", [file("a", size: 600), file("b", size: 300)]), file("c", size: 100)])
        root.finalizeTree()
        let layout = TreemapLayoutEngine().makeLayout(root: root, size: CGSize(width: 320, height: 200), sizeMetric: .fileSize)

        let image = try #require(TreemapRasterizer(colorScheme: .dark, sizeMetric: .fileSize, scale: 2)
            .render(layout, transform: TreemapTransform(zoom: 3, pan: CGPoint(x: -100, y: -50))))
        #expect(image.width == 640)
        #expect(image.height == 400)
    }

    @Test("A chain of single-folder descendants shares one header")
    func singleFolderChainSharesHeader() throws {
        let app = directory("Tool.app", [directory("Contents", [file("a", size: 600), file("b", size: 400)])])
        let root = directory("/scan", [app, file("c", size: 1000)])
        let items = layout(root)

        let header = try #require(items.first { $0.node === app })
        #expect(header.title == "Tool.app › Contents")
        let contents = try #require(items.first { $0.node.name == "Contents" })
        #expect(!contents.hasHeader)
        let content = TreemapLayoutEngine.contentBounds(ofHeadedFrame: header.rect)
        #expect(contents.rect.y == content.y && contents.rect.height == content.height)
    }

    @Test("Children too small to draw are grouped into one aggregate block")
    func tinyChildrenAreAggregated() throws {
        let tiny = (0..<50).map { file("tiny\($0)", size: 1) }
        let folder = directory("folder", [file("big", size: 1_000_000)] + tiny)
        let root = directory("/scan", [folder])
        let layout = TreemapLayoutEngine().makeLayout(root: root.finalized(), size: CGSize(width: 800, height: 600), sizeMetric: .fileSize)

        #expect(!layout.items.contains { $0.node.name.hasPrefix("tiny") })
        let aggregate = try #require(layout.items.first { $0.isAggregate })
        #expect(aggregate.node === folder)
        #expect(layout.item(representing: folder)?.isAggregate == false)
    }

    @Test("Folder color mode gives each top-level branch its own hue, whatever the file kinds")
    func folderModeColorsByBranch() throws {
        let one = directory("one", [file("a", size: 500)])
        let two = directory("two", [file("b", size: 400)])
        let root = directory("/scan", [one, two])
        let layout = TreemapLayoutEngine(colorMode: .folder)
            .makeLayout(root: root.finalized(), size: CGSize(width: 800, height: 600), sizeMetric: .fileSize)

        let leafA = try #require(layout.items.first { $0.node.name == "a" })
        let leafB = try #require(layout.items.first { $0.node.name == "b" })
        // Both leaves are documents, so only the branch can tell them apart.
        #expect(leafA.color != leafB.color)
    }

    @Test("Sidebar rows take the hue of their branch under the shown folder, and gray outside it")
    func sidebarColorsFollowBranches() throws {
        let nested = directory("nested", [file("n", size: 100)])
        let small = directory("small", [nested])
        let large = directory("large", [file("l", size: 900)])
        let outside = directory("outside", [file("o", size: 50)])
        let shown = directory("shown", [small, large])
        _ = directory("/scan", [shown, outside]).finalized()

        let colors = SidebarColors(viewRoot: shown, sizeMetric: .fileSize, mode: .folder)
        let swatches = TreemapPalette.branchSwatches
        #expect(colors.color(for: large) == swatches[0])
        #expect(colors.color(for: small) == swatches[1])
        #expect(colors.color(for: nested) == swatches[1])
        #expect(colors.color(for: outside) == .gray)
        #expect(colors.color(for: shown) == .gray)
    }
}

private extension FileNode {
    func finalized() -> FileNode {
        finalizeTree()
        return self
    }
}
