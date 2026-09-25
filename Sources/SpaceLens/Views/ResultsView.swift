import SwiftUI

/// Detail column for a completed scan: breadcrumb, chart and legend.
struct ResultsView: View {
    let results: ResultsModel
    let sizeMetric: SizeMetric
    let colorMode: ColorMode
    let chartStyle: ChartStyle
    /// Leaves the Cleanup list for a chart, showing `node` there.
    let onShowInChart: (FileNode) -> Void

    var body: some View {
        let viewRoot = results.viewRoot

        VStack(spacing: 0) {
            if results.report.inaccessibleCount > 0 {
                InaccessibleFoldersBanner(report: results.report)
            }

            // Cleanup covers the whole scan, so the folder navigation and legend only belong to the charts.
            if chartStyle != .cleanup {
                BreadcrumbBar(
                    breadcrumbs: results.breadcrumbs,
                    sizeMetric: sizeMetric,
                    onNavigate: { results.open($0) }
                )
            }

            switch chartStyle {
            case .treemap:
                TreemapView(
                    root: viewRoot,
                    selection: results.selection,
                    sizeMetric: sizeMetric,
                    colorMode: colorMode,
                    viewport: results.viewport,
                    onSelect: { results.select($0) },
                    onOpen: { results.open($0) }
                )
            case .sunburst:
                SunburstView(
                    root: viewRoot,
                    selection: results.selection,
                    sizeMetric: sizeMetric,
                    colorMode: colorMode,
                    canNavigateUp: results.canNavigateUp,
                    onSelect: { results.select($0) },
                    onOpen: { results.open($0) },
                    onNavigateUp: { results.navigateUp() }
                )
            case .cleanup:
                CleanupView(results: results, onShowInChart: onShowInChart)
            }

            if chartStyle != .cleanup {
                switch colorMode {
                case .folder:
                    FolderLegendBar(node: viewRoot, sizeMetric: sizeMetric, onSelect: { results.select($0) })
                case .kind:
                    CategoryLegendBar(results: results, node: viewRoot)
                }
            }
        }
        .navigationTitle(viewRoot.displayName)
        .navigationSubtitle("\(ByteFormatter.string(from: viewRoot.size(for: sizeMetric))) · \(viewRoot.fileCount.formatted()) files")
    }
}

/// Legend bar chrome shared by both legends.
private struct LegendBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        FittingHStack(spacing: 16) {
            content
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .clipped()
        .overlay(alignment: .top) { Divider() }
    }
}

private struct LegendEntry: View {
    let color: Color
    let title: String
    let size: Int64

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .lineLimit(1)
            Text(ByteFormatter.string(from: size))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The largest top-level items of the shown folder, in the hue each one's branch is drawn in.
private struct FolderLegendBar: View {
    private static let maxEntries = 8

    let node: FileNode
    let sizeMetric: SizeMetric
    let onSelect: (FileNode) -> Void

    var body: some View {
        let children = TreemapLayoutEngine.orderedChildren(of: node, sizeMetric: sizeMetric).prefix(Self.maxEntries)
        let swatches = TreemapPalette.branchSwatches
        LegendBar {
            ForEach(Array(children.enumerated()), id: \.element) { index, child in
                LegendEntry(color: swatches[index % swatches.count], title: child.name, size: child.size(for: sizeMetric))
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(child) }
            }
        }
    }
}

/// Category totals for the shown folder.
private struct CategoryLegendBar: View {
    private static let maxEntries = 8

    let results: ResultsModel
    let node: FileNode
    @State private var breakdown: CategoryBreakdown = []

    var body: some View {
        LegendBar {
            ForEach(breakdown.prefix(Self.maxEntries), id: \.category) { entry in
                LegendEntry(color: entry.category.color, title: entry.category.displayName, size: entry.size)
            }
        }
        .task(id: node) {
            // The previous folder's legend stays up until this one is ready, so navigating doesn't flash empty.
            let result = await results.categoryBreakdown(of: node)
            if !Task.isCancelled { breakdown = result }
        }
    }
}

/// A row that shows as many whole subviews as fit and hides the rest. Unlike an `HStack` of fixed-size
/// items, its minimum width is zero, so it never forces its container (and the window) wider.
private struct FittingHStack: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var isFull = false
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            isFull = isFull || x + size.width > bounds.maxX
            if isFull {
                // Beyond the trailing edge, where the container clips it: hidden without changing view identity.
                // A zero proposal alone isn't enough, since fixed-size parts such as the color dot still draw.
                subview.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.minY), proposal: .zero)
            } else {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }
}
