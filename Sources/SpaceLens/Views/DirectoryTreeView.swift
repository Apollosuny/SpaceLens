import SwiftUI

/// Folder outline of the scan. Expansion lives in `ResultsModel`, so drilling into the treemap reveals the
/// matching row here.
struct DirectoryTreeView: View {
    let results: ResultsModel
    let sizeMetric: SizeMetric
    let colorMode: ColorMode

    var body: some View {
        let colors = SidebarColors(viewRoot: results.viewRoot, sizeMetric: sizeMetric, mode: colorMode)

        ScrollViewReader { proxy in
            List(selection: selection) {
                Section {
                    ForEach(results.root.directoryChildren, id: \.self) { node in
                        DirectoryOutlineRow(node: node, results: results, sizeMetric: sizeMetric, colors: colors)
                    }
                } header: {
                    HStack {
                        Text("Contents")
                        Spacer()
                        Text(ByteFormatter.string(from: results.root.size(for: sizeMetric)))
                            .monospacedDigit()
                    }
                }
            }
            .listStyle(.sidebar)
            .onChange(of: results.selection) { _, selected in
                // Files are not listed; scroll to their folder instead.
                guard let selected, let row = selected.isDirectory ? selected : selected.parent, row !== results.root else { return }
                proxy.scrollTo(row)
            }
        }
    }

    private var selection: Binding<FileNode?> {
        Binding(get: { results.selection }, set: { results.select($0) })
    }
}

private struct DirectoryOutlineRow: View {
    let node: FileNode
    let results: ResultsModel
    let sizeMetric: SizeMetric
    let colors: SidebarColors

    var body: some View {
        if node.directoryChildren.isEmpty {
            DirectoryRow(node: node, sizeMetric: sizeMetric, color: colors.color(for: node))
        } else {
            DisclosureGroup(isExpanded: isExpanded) {
                ForEach(node.directoryChildren, id: \.self) { child in
                    DirectoryOutlineRow(node: child, results: results, sizeMetric: sizeMetric, colors: colors)
                }
            } label: {
                DirectoryRow(node: node, sizeMetric: sizeMetric, color: colors.color(for: node))
            }
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(get: { results.expandedFolders.contains(node) }, set: { results.setExpanded(node, $0) })
    }
}

struct DirectoryRow: View {
    let node: FileNode
    let sizeMetric: SizeMetric
    /// Icon and share bar color, matching how the chart draws this folder.
    let color: Color

    /// `.increased` on the selected row, whose background is the accent color.
    @Environment(\.backgroundProminence) private var backgroundProminence

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(iconStyle)

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(node.attributes.contains(.hidden) ? .secondary : .primary)

            Spacer()

            Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .overlay(alignment: .bottomLeading) {
            ShareBar(fraction: shareOfParent, color: color, isOnAccent: backgroundProminence == .increased)
                .padding(.leading, 22)
                .offset(y: 3)
        }
    }

    /// The label color on the selected row, where the accent is the background.
    private var iconStyle: AnyShapeStyle {
        backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(color)
    }

    private var shareOfParent: Double {
        guard let parent = node.parent else { return 0 }
        let total = parent.size(for: sizeMetric)
        return total > 0 ? Double(node.size(for: sizeMetric)) / Double(total) : 0
    }
}

/// Thin proportional bar under a sidebar row. Scales a capsule instead of measuring with a
/// `GeometryReader`, which would re-lay out every row during column animations.
private struct ShareBar: View {
    let fraction: Double
    let color: Color
    let isOnAccent: Bool

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(isOnAccent ? AnyShapeStyle(.primary) : AnyShapeStyle(color))
                    .scaleEffect(x: min(max(fraction, 0), 1), y: 1, anchor: .leading)
            }
            .frame(height: 2)
            .accessibilityHidden(true)
    }
}

/// Sidebar colors that tie rows to the chart. In `.folder` mode a folder inside the shown folder takes
/// the hue of its top-level branch there, as in the chart and its legend; folders outside the chart are
/// gray. In `.kind` mode a folder takes its category color (gray for plain folders).
struct SidebarColors {
    private let viewRoot: FileNode
    private let mode: ColorMode
    private let branchByChild: [ObjectIdentifier: Int]

    init(viewRoot: FileNode, sizeMetric: SizeMetric, mode: ColorMode) {
        self.viewRoot = viewRoot
        self.mode = mode
        var branchByChild: [ObjectIdentifier: Int] = [:]
        if mode == .folder {
            for (index, child) in TreemapLayoutEngine.orderedChildren(of: viewRoot, sizeMetric: sizeMetric).enumerated() {
                branchByChild[ObjectIdentifier(child)] = index
            }
        }
        self.branchByChild = branchByChild
    }

    func color(for node: FileNode) -> Color {
        switch mode {
        case .kind:
            return node.category.color
        case .folder:
            var current = node
            while let parent = current.parent, parent !== viewRoot { current = parent }
            guard current.parent === viewRoot, let branch = branchByChild[ObjectIdentifier(current)] else { return .gray }
            let swatches = TreemapPalette.branchSwatches
            return swatches[branch % swatches.count]
        }
    }
}
