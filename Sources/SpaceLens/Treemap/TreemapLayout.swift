import SwiftUI

struct TreemapRect: Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var area: Double { width * height }
    var minSide: Double { min(width, height) }

    func contains(point: CGPoint) -> Bool {
        point.x >= x && point.x <= x + width &&
        point.y >= y && point.y <= y + height
    }
}

struct TreemapItem: Identifiable, Sendable {
    let id: Int
    let node: FileNode
    let rect: TreemapRect
    let depth: Int
    let color: CGColor
    /// True when children are laid out on top of this item, hiding everything but its border.
    var hasChildren: Bool = false
    /// True when the top `TreemapLayoutEngine.headerHeight` points of `rect` are a name bar kept clear of children.
    var hasHeader: Bool = false
    /// Header text when it differs from the node name: a chain of single-folder descendants shares one header.
    var title: String?
    /// A block standing for the node's children too small to draw individually.
    var isAggregate: Bool = false
}

/// Chart colors resolved for one appearance. Layout runs off the main actor, outside any view
/// environment, so the adaptive system colors are resolved up front.
struct TreemapPalette: Sendable {
    /// One hue per top-level folder in `.folder` mode, in size order. Apple system colors, ordered so
    /// neighbours in size contrast.
    static let branchSwatches: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red, .indigo, .mint, .cyan, .brown]

    let background: CGColor
    private let isDark: Bool
    private let neutralAggregate: CGColor
    private let categoryColors: [FileCategory: CGColor]
    private let branchColors: [CGColor]
    private let frameColors: (odd: CGColor, even: CGColor)

    init(colorScheme: ColorScheme) {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        categoryColors = Dictionary(uniqueKeysWithValues: FileCategory.allCases.map {
            ($0, $0.color.resolve(in: environment).cgColor)
        })
        branchColors = Self.branchSwatches.map { $0.resolve(in: environment).cgColor }
        isDark = colorScheme == .dark
        // Matches textBackgroundColor; nested folder frames alternate two neutral steps so nesting stays readable.
        if isDark {
            background = CGColor(gray: 0.118, alpha: 1)
            neutralAggregate = CGColor(gray: 0.3, alpha: 1)
            frameColors = (odd: CGColor(gray: 0.2, alpha: 1), even: CGColor(gray: 0.25, alpha: 1))
        } else {
            background = CGColor(gray: 1, alpha: 1)
            neutralAggregate = CGColor(gray: 0.84, alpha: 1)
            frameColors = (odd: CGColor(gray: 0.945, alpha: 1), even: CGColor(gray: 0.895, alpha: 1))
        }
    }

    func color(for category: FileCategory) -> CGColor {
        categoryColors[category] ?? background
    }

    func branchColor(_ branch: Int) -> CGColor {
        branchColors[branch % branchColors.count]
    }

    /// Fill of a file (or a folder drawn as a single block). In `.folder` mode it is its top-level folder's
    /// hue, lightened with depth; in both modes neighbouring siblings alternate tints so they stay distinct.
    func fill(for node: FileNode, branch: Int?, depth: Int, sibling: Int, mode: ColorMode) -> CGColor {
        let siblingStep = sibling.isMultiple(of: 2) ? 0 : 0.12
        guard mode == .folder, let branch else {
            return lighten(color(for: node.category), by: siblingStep)
        }
        return lighten(branchColor(branch), by: min(0.4, Double(max(0, depth - 1)) * 0.1) + siblingStep)
    }

    /// Frame painted behind a folder's children: a pale wash of its hue in `.folder` mode, neutral
    /// otherwise. Nested frames alternate two steps so nesting stays readable.
    func frame(depth: Int, branch: Int?, mode: ColorMode) -> CGColor {
        guard mode == .folder, let branch else {
            return depth.isMultiple(of: 2) ? frameColors.even : frameColors.odd
        }
        let wash = (isDark ? 0.72 : 0.84) - (depth.isMultiple(of: 2) ? 0.06 : 0)
        return mix(branchColor(branch), background, wash)
    }

    /// Fill of blocks that group children too small to draw.
    func aggregate(branch: Int?, mode: ColorMode) -> CGColor {
        guard mode == .folder, let branch else { return neutralAggregate }
        return mix(branchColor(branch), background, isDark ? 0.55 : 0.62)
    }

    /// Toward white in light mode; toward the background, more gently, in dark mode so colors stay rich.
    private func lighten(_ color: CGColor, by amount: Double) -> CGColor {
        guard amount > 0 else { return color }
        return isDark ? mix(color, background, amount * 0.6) : mix(color, CGColor(gray: 1, alpha: 1), amount)
    }

    /// `color` moved `amount` (0…1) of the way to `target`, in sRGB.
    private func mix(_ color: CGColor, _ target: CGColor, _ amount: Double) -> CGColor {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let from = color.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              let to = target.converted(to: space, intent: .defaultIntent, options: nil)?.components,
              from.count >= 3, to.count >= 3
        else { return color }
        let t = CGFloat(min(max(amount, 0), 1))
        let channel = { (index: Int) in min(max(from[index] + (to[index] - from[index]) * t, 0), 1) }
        return CGColor(srgbRed: channel(0), green: channel(1), blue: channel(2), alpha: 1)
    }
}

struct TreemapLayoutEngine: Sendable {
    /// Height of the name bar drawn at the top of large folder frames.
    static let headerHeight: Double = 16
    /// Inset between a headed folder frame and its children on the left, right and bottom.
    static let framePadding: Double = 2
    /// Folders smaller than this get no header, so small rects keep their area for content.
    static let minHeaderFrameSize = CGSize(width: 72, height: 44)
    /// Children smaller than this (about 10×10 points) are grouped into one aggregate block: individually
    /// they are unreadable confetti.
    static let minTileArea: Double = 100

    let maxDepth: Int
    let minPixelArea: Double
    let palette: TreemapPalette
    let colorMode: ColorMode

    /// Rects under 3×3 points are indistinguishable from their neighbours but dominate the item count.
    init(maxDepth: Int = 12, minPixelArea: Double = 9, colorScheme: ColorScheme = .light, colorMode: ColorMode = .kind) {
        self.maxDepth = maxDepth
        self.minPixelArea = minPixelArea
        self.palette = TreemapPalette(colorScheme: colorScheme)
        self.colorMode = colorMode
    }

    func layout(root: FileNode, in bounds: TreemapRect, sizeMetric: SizeMetric = .fileSize) -> [TreemapItem] {
        var items: [TreemapItem] = []
        items.reserveCapacity(8192)
        var nextID = 0
        layoutNode(root, in: bounds, depth: 0, branch: nil, sibling: 0, sizeMetric: sizeMetric, items: &items, nextID: &nextID)
        return items
    }

    func makeLayout(root: FileNode, size: CGSize, sizeMetric: SizeMetric) -> TreemapLayout {
        let bounds = TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        return TreemapLayout(items: layout(root: root, in: bounds, sizeMetric: sizeMetric), size: size)
    }

    /// Children with a positive size, largest first: the order they are laid out in and, at the view
    /// root, the order that assigns `.folder` hues.
    static func orderedChildren(of node: FileNode, sizeMetric: SizeMetric) -> [FileNode] {
        let children = node.children.filter { $0.size(for: sizeMetric) > 0 }
        // `finalizeTree` already sorts by logical size.
        return sizeMetric == .fileSize ? children : children.sorted { $0.size(for: sizeMetric) > $1.size(for: sizeMetric) }
    }

    private func layoutNode(
        _ node: FileNode,
        in bounds: TreemapRect,
        depth: Int,
        branch: Int?,
        sibling: Int,
        sizeMetric: SizeMetric,
        items: inout [TreemapItem],
        nextID: inout Int
    ) {
        guard bounds.area >= minPixelArea, !Task.isCancelled else { return }

        // Leaf node (file or empty/childless directory)
        if !node.isDirectory || node.children.isEmpty || depth >= maxDepth {
            let itemID = nextID; nextID += 1
            items.append(TreemapItem(
                id: itemID,
                node: node,
                rect: bounds,
                depth: depth,
                color: palette.fill(for: node, branch: branch, depth: depth, sibling: sibling, mode: colorMode)
            ))
            return
        }

        var children = Self.orderedChildren(of: node, sizeMetric: sizeMetric)
        guard !children.isEmpty else {
            let itemID = nextID; nextID += 1
            items.append(TreemapItem(
                id: itemID,
                node: node,
                rect: bounds,
                depth: depth,
                color: palette.fill(for: node, branch: branch, depth: depth, sibling: sibling, mode: colorMode)
            ))
            return
        }

        // The directory is painted as a neutral frame behind its children; the gaps between them show it.
        // The view root is not headed: the breadcrumb bar already names it.
        let hasHeader = depth > 0
            && bounds.width >= Self.minHeaderFrameSize.width
            && bounds.height >= Self.minHeaderFrameSize.height
        let frameColor = depth == 0 ? palette.background : palette.frame(depth: depth, branch: branch, mode: colorMode)
        let headerIndex = items.count
        let itemID = nextID; nextID += 1
        items.append(TreemapItem(
            id: itemID,
            node: node,
            rect: bounds,
            depth: depth,
            color: frameColor,
            hasChildren: true,
            hasHeader: hasHeader
        ))

        let contentBounds = hasHeader ? Self.contentBounds(ofHeadedFrame: bounds) : bounds
        guard contentBounds.area > 0 else { return }

        // A folder whose only content is another folder (App.app › Contents › …) would stack one header per
        // level; instead the chain shares this header and each link is an invisible frame over the content.
        var container = node
        var containerDepth = depth
        if hasHeader {
            var names = [node.name]
            while children.count == 1, let only = children.first, only.isDirectory, containerDepth + 1 < maxDepth {
                let grandchildren = Self.orderedChildren(of: only, sizeMetric: sizeMetric)
                guard !grandchildren.isEmpty else { break }
                containerDepth += 1
                let linkID = nextID; nextID += 1
                items.append(TreemapItem(
                    id: linkID,
                    node: only,
                    rect: contentBounds,
                    depth: containerDepth,
                    color: frameColor,
                    hasChildren: true
                ))
                names.append(only.name)
                container = only
                children = grandchildren
            }
            if names.count > 1 { items[headerIndex].title = names.joined(separator: " › ") }
        }

        let totalSize = Double(children.reduce(0) { $0 + $1.size(for: sizeMetric) })
        guard totalSize > 0 else { return }
        var sizes = children.map { Double($0.size(for: sizeMetric)) / totalSize * contentBounds.area }

        // Children are sorted by size, so everything from the first too-small one on is grouped.
        var aggregateArea = 0.0
        if let firstSmall = sizes.firstIndex(where: { $0 < Self.minTileArea }), sizes.count - firstSmall >= 2 {
            aggregateArea = sizes[firstSmall...].reduce(0, +)
            sizes.removeSubrange(firstSmall...)
            children.removeSubrange(firstSmall...)
            sizes.append(aggregateArea)
        }

        let rects = squarify(sizes: sizes, in: contentBounds)
        for (i, child) in children.enumerated() where i < rects.count {
            // Each child of the view root starts its own hue.
            layoutNode(child, in: rects[i], depth: containerDepth + 1, branch: depth == 0 ? i : branch, sibling: i,
                       sizeMetric: sizeMetric, items: &items, nextID: &nextID)
        }
        if aggregateArea > 0, let rect = rects.last, rect.area >= minPixelArea {
            let aggregateID = nextID; nextID += 1
            items.append(TreemapItem(
                id: aggregateID,
                node: container,
                rect: rect,
                depth: containerDepth + 1,
                color: palette.aggregate(branch: depth == 0 ? rects.count - 1 : branch, mode: colorMode),
                isAggregate: true
            ))
        }
    }

    /// The area inside a headed folder frame that its children fill.
    static func contentBounds(ofHeadedFrame frame: TreemapRect) -> TreemapRect {
        TreemapRect(
            x: frame.x + framePadding,
            y: frame.y + headerHeight,
            width: max(0, frame.width - 2 * framePadding),
            height: max(0, frame.height - headerHeight - framePadding)
        )
    }

    private func squarify(sizes: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        guard !sizes.isEmpty else { return [] }

        var rects = [TreemapRect](repeating: TreemapRect(x: 0, y: 0, width: 0, height: 0), count: sizes.count)
        var remaining = bounds
        var index = 0

        while index < sizes.count {
            let shortSide = remaining.minSide

            // Find the optimal row
            var row: [Int] = [index]
            var rowSum = sizes[index]
            var bestWorst = worstAspectRatio(row: [sizes[index]], totalArea: rowSum, shortSide: shortSide)

            var next = index + 1
            while next < sizes.count {
                let newSum = rowSum + sizes[next]
                var rowSizes = row.map { sizes[$0] }
                rowSizes.append(sizes[next])
                let newWorst = worstAspectRatio(row: rowSizes, totalArea: newSum, shortSide: shortSide)
                if newWorst > bestWorst {
                    break
                }
                bestWorst = newWorst
                row.append(next)
                rowSum = newSum
                next += 1
            }

            // Lay out the row
            let rowFraction = rowSum / (remaining.width * remaining.height)
            let isHorizontal = remaining.width >= remaining.height

            if isHorizontal {
                let rowWidth = remaining.width * rowFraction
                var yOffset = remaining.y
                for idx in row {
                    let itemHeight = (sizes[idx] / rowSum) * remaining.height
                    rects[idx] = TreemapRect(
                        x: remaining.x,
                        y: yOffset,
                        width: rowWidth,
                        height: itemHeight
                    )
                    yOffset += itemHeight
                }
                remaining = TreemapRect(
                    x: remaining.x + rowWidth,
                    y: remaining.y,
                    width: remaining.width - rowWidth,
                    height: remaining.height
                )
            } else {
                let rowHeight = remaining.height * rowFraction
                var xOffset = remaining.x
                for idx in row {
                    let itemWidth = (sizes[idx] / rowSum) * remaining.width
                    rects[idx] = TreemapRect(
                        x: xOffset,
                        y: remaining.y,
                        width: itemWidth,
                        height: rowHeight
                    )
                    xOffset += itemWidth
                }
                remaining = TreemapRect(
                    x: remaining.x,
                    y: remaining.y + rowHeight,
                    width: remaining.width,
                    height: remaining.height - rowHeight
                )
            }

            index = next
        }

        return rects
    }

    private func worstAspectRatio(row: [Double], totalArea: Double, shortSide: Double) -> Double {
        guard shortSide > 0 && totalArea > 0 else { return Double.infinity }
        let s2 = shortSide * shortSide
        var worst: Double = 0
        for size in row {
            guard size > 0 else { continue }
            let ratio = max(
                (s2 * size) / (totalArea * totalArea),
                (totalArea * totalArea) / (s2 * size)
            )
            worst = max(worst, ratio)
        }
        return worst
    }
}

/// A laid-out treemap and the indexes needed to query it from the view.
struct TreemapLayout: Sendable {
    /// Items in pre-order: every item is followed by its whole subtree.
    let items: [TreemapItem]
    /// The size, in points, the items were laid out in.
    let size: CGSize
    /// For each item, the index one past the last item of its subtree.
    private let subtreeEnd: [Int]
    private let indexByNode: [ObjectIdentifier: Int]

    init(items: [TreemapItem], size: CGSize) {
        self.items = items
        self.size = size

        var subtreeEnd = Array(repeating: items.count, count: items.count)
        var openAncestors: [Int] = []
        for (index, item) in items.enumerated() {
            while let last = openAncestors.last, items[last].depth >= item.depth {
                subtreeEnd[last] = index
                openAncestors.removeLast()
            }
            openAncestors.append(index)
        }
        self.subtreeEnd = subtreeEnd

        var indexByNode: [ObjectIdentifier: Int] = [:]
        indexByNode.reserveCapacity(items.count)
        for (index, item) in items.enumerated() where !item.isAggregate {
            indexByNode[ObjectIdentifier(item.node)] = index
        }
        self.indexByNode = indexByNode
    }

    /// The deepest item containing `point` (content coordinates). Descends from the root, testing only the
    /// children of each hit, instead of scanning every item.
    func item(at point: CGPoint) -> TreemapItem? {
        guard let first = items.first, first.rect.contains(point: point) else { return nil }
        var current = 0
        descending: while true {
            var child = current + 1
            while child < subtreeEnd[current] {
                if items[child].rect.contains(point: point) {
                    current = child
                    continue descending
                }
                child = subtreeEnd[child]
            }
            return items[current]
        }
    }

    /// The item drawn for `node` or, when it is too small to be drawn, for its nearest drawn ancestor.
    /// Nil when `node` lies outside the laid-out subtree.
    func item(representing node: FileNode) -> TreemapItem? {
        var candidate: FileNode? = node
        while let current = candidate {
            if let index = indexByNode[ObjectIdentifier(current)] { return items[index] }
            candidate = current.parent
        }
        return nil
    }

    /// Whether `item` is the laid-out root.
    func isRoot(_ item: TreemapItem) -> Bool {
        items.first?.id == item.id
    }
}
