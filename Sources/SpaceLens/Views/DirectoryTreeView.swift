import SwiftUI

struct DirectoryTreeView: View {
    let root: FileNode
    @Binding var selectedNode: FileNode?
    let sizeMetric: SizeMetric

    var body: some View {
        // Nodes are Hashable by identity, so selection needs no tree search.
        List(selection: $selectedNode) {
            OutlineGroup(root.directoryChildren, id: \.self, children: \.optionalDirectoryChildren) { node in
                DirectoryRow(node: node, sizeMetric: sizeMetric)
            }
        }
        .listStyle(.sidebar)
    }
}

struct DirectoryRow: View {
    let node: FileNode
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))

            Text(node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(node.attributes.contains(.hidden) ? .secondary : .primary)

            Spacer()

            Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private extension FileNode {
    var optionalDirectoryChildren: [FileNode]? {
        directoryChildren.isEmpty ? nil : directoryChildren
    }
}
