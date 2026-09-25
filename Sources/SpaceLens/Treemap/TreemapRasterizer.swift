import AppKit
import CoreText
import SwiftUI

/// Zoom and pan applied to a treemap layout: screen = pan + content × zoom.
struct TreemapTransform: Equatable, Sendable {
    var zoom: CGFloat = 1
    var pan: CGPoint = .zero

    func screenRect(for rect: TreemapRect) -> CGRect {
        CGRect(x: pan.x + rect.x * zoom, y: pan.y + rect.y * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }

    func contentPoint(for screenPoint: CGPoint) -> CGPoint {
        CGPoint(x: (screenPoint.x - pan.x) / zoom, y: (screenPoint.y - pan.y) / zoom)
    }
}

/// Draws a treemap into a bitmap off the main actor. The view only composites the image, so sidebar and
/// inspector animations or window resizing never redraw tens of thousands of rects and labels per frame.
struct TreemapRasterizer: Sendable {
    /// Rects smaller than this (in points) get no gap or rounded corners: invisible at that size, and they
    /// dominate the item count.
    private static let minDetailedSide: CGFloat = 3
    /// Rects at least this large get the full corner radius.
    private static let minRoundedSide: CGFloat = 12
    /// Half the gap between neighbouring rects; the parent frame shows through it.
    private static let gapInset: CGFloat = 0.75

    let colorScheme: ColorScheme
    let sizeMetric: SizeMetric
    /// Pixels per point.
    let scale: CGFloat

    /// Renders the part of `layout` visible through `transform` at the layout's size. Items are laid out so
    /// that a child lies inside its parent and siblings never overlap, so filling depth by depth (one path
    /// per color) preserves the stacking of drawing item by item.
    func render(_ layout: TreemapLayout, transform: TreemapTransform) -> CGImage? {
        let pixelWidth = Int((layout.size.width * scale).rounded(.up))
        let pixelHeight = Int((layout.size.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        // Top-left origin in points, like SwiftUI. Text is flipped back upright through the text matrix.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        let viewport = CGRect(origin: .zero, size: layout.size)
        context.setFillColor(TreemapPalette(colorScheme: colorScheme).background)
        context.fill(viewport)

        var layers: [DepthLayer] = []
        for item in layout.items {
            if Task.isCancelled { return nil }
            let screenRect = transform.screenRect(for: item.rect)
            guard screenRect.intersects(viewport) else { continue }

            while layers.count <= item.depth { layers.append(DepthLayer()) }
            let isDetailed = screenRect.width >= Self.minDetailedSide && screenRect.height >= Self.minDetailedSide
            let drawRect = isDetailed ? screenRect.insetBy(dx: Self.gapInset, dy: Self.gapInset) : screenRect
            let cornerRadius: CGFloat = min(screenRect.width, screenRect.height) >= Self.minRoundedSide ? 4 : (isDetailed ? 1 : 0)
            layers[item.depth].addFill(drawRect, color: item.color, cornerRadius: cornerRadius)

            if item.hasHeader && screenRect.width > 40 {
                layers[item.depth].headers.append((item, drawRect))
            } else if !item.hasChildren && !item.isAggregate && screenRect.width > 56 && screenRect.height > 20 {
                // A container's label would be painted over by its children, so only leaves get one.
                layers[item.depth].labels.append((item, drawRect))
            }
        }

        let text = TextStyles(colorScheme: colorScheme)
        let headerHeight = min(TreemapLayoutEngine.headerHeight * transform.zoom, 16)
        for layer in layers {
            for (color, path) in layer.fills {
                context.addPath(path)
                context.setFillColor(color)
                context.fillPath()
            }
            for (item, rect) in layer.headers {
                drawHeader(for: item, in: rect, barHeight: headerHeight, text: text, context: context)
            }
            for (item, rect) in layer.labels {
                drawLabels(for: item, in: rect, text: text, context: context)
            }
        }
        return context.makeImage()
    }

    /// Folder name on the left of the header bar and, when it fits, the folder size on the right.
    private func drawHeader(for item: TreemapItem, in rect: CGRect, barHeight: CGFloat, text: TextStyles, context: CGContext) {
        let sizeLine = text.line(ByteFormatter.string(from: item.node.size(for: sizeMetric)), font: text.smallFont)
        let sizeWidth = CGFloat(CTLineGetTypographicBounds(sizeLine, nil, nil, nil))
        let showsSize = rect.width > sizeWidth + 60
        let nameWidth = rect.width - 12 - (showsSize ? sizeWidth + 8 : 0)
        let barTop = rect.minY + 1

        text.draw(item.title ?? item.node.name, font: text.boldFont, color: text.headerNameColor, maxWidth: nameWidth,
                  x: rect.minX + 6, centeredIn: barTop, height: barHeight, context: context)
        if showsSize {
            text.draw(sizeLine, font: text.smallFont, color: text.headerSizeColor,
                      x: rect.maxX - 6 - sizeWidth, centeredIn: barTop, height: barHeight, context: context)
        }
    }

    /// Name label (11pt regardless of zoom) plus a size label for larger rects.
    private func drawLabels(for item: TreemapItem, in rect: CGRect, text: TextStyles, context: CGContext) {
        let maxWidth = rect.width - 10
        text.draw(item.node.name, font: text.boldFont, color: text.leafNameColor, maxWidth: maxWidth,
                  x: rect.minX + 5, centeredIn: rect.minY + 3, height: min(rect.height - 4, 15), context: context)

        guard rect.width > 64 && rect.height > 36 else { return }
        text.draw(ByteFormatter.string(from: item.node.size(for: sizeMetric)), font: text.smallFont,
                  color: text.leafSizeColor, maxWidth: maxWidth,
                  x: rect.minX + 5, centeredIn: rect.minY + 18, height: 14, context: context)
    }
}

private struct DepthLayer {
    /// Keyed by color; `TreemapItem.color` takes one of a few values per depth (one per category).
    var fills: [CGColor: CGMutablePath] = [:]
    var headers: [(TreemapItem, CGRect)] = []
    var labels: [(TreemapItem, CGRect)] = []

    mutating func addFill(_ rect: CGRect, color: CGColor, cornerRadius: CGFloat) {
        let path = fills[color] ?? {
            let path = CGMutablePath()
            fills[color] = path
            return path
        }()
        if cornerRadius > 0 {
            path.addRoundedRect(in: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius)
        } else {
            path.addRect(rect)
        }
    }
}

/// Core Text line drawing for one render. Colors come from the context fill color.
private struct TextStyles {
    let boldFont: CTFont
    let smallFont: CTFont
    let headerNameColor: CGColor
    let headerSizeColor: CGColor
    /// Leaf labels sit on saturated system colors in both appearances, so they are always dark.
    let leafNameColor = CGColor(gray: 0, alpha: 0.85)
    let leafSizeColor = CGColor(gray: 0, alpha: 0.62)

    init(colorScheme: ColorScheme) {
        boldFont = NSFont.systemFont(ofSize: 11, weight: .semibold) as CTFont
        smallFont = NSFont.systemFont(ofSize: 10) as CTFont
        let labelGray: CGFloat = colorScheme == .dark ? 1 : 0
        headerNameColor = CGColor(gray: labelGray, alpha: 0.85)
        headerSizeColor = CGColor(gray: labelGray, alpha: 0.5)
    }

    func line(_ string: String, font: CTFont) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    }

    /// Draws `string` truncated with an ellipsis to `maxWidth`, vertically centered in `height` from `top`.
    func draw(_ string: String, font: CTFont, color: CGColor, maxWidth: CGFloat,
              x: CGFloat, centeredIn top: CGFloat, height: CGFloat, context: CGContext) {
        guard maxWidth > 8 else { return }
        var line = line(string, font: font)
        if CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > maxWidth {
            guard let truncated = CTLineCreateTruncatedLine(line, Double(maxWidth), .end, self.line("…", font: font)) else { return }
            line = truncated
        }
        draw(line, font: font, color: color, x: x, centeredIn: top, height: height, context: context)
    }

    func draw(_ line: CTLine, font: CTFont, color: CGColor, x: CGFloat, centeredIn top: CGFloat, height: CGFloat, context: CGContext) {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        context.setFillColor(color)
        context.textPosition = CGPoint(x: x, y: top + (height - ascent - descent) / 2 + ascent)
        CTLineDraw(line, context)
    }
}
