import SwiftUI

struct DetailPanelView: View {
    let node: FileNode

    @State private var breakdown: [(category: FileCategory, size: Int64)] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 10) {
                    Image(systemName: node.isDirectory ? "folder.fill" : node.category.sfSymbol)
                        .font(.title2)
                        .foregroundStyle(node.category.color)

                    VStack(alignment: .leading) {
                        Text(node.name)
                            .font(.headline)
                            .lineLimit(2)
                        Text(node.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }

                Divider()

                // Size info
                LabeledContent("Logical Size", value: ByteFormatter.string(from: node.totalSize))
                LabeledContent("Physical Size", value: ByteFormatter.string(from: node.totalAllocatedSize))

                ForEach(attributeNotes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if node.isDirectory {
                    LabeledContent("Files", value: "\(node.fileCount.formatted())")
                    LabeledContent("Directories", value: "\(node.directoryCount.formatted())")
                }

                if let date = node.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .shortened))
                }

                if node.isDirectory {
                    Divider()

                    // Category breakdown
                    Text("Category Breakdown")
                        .font(.headline)

                    let total = max(1, breakdown.reduce(0) { $0 + $1.size })

                    // Bar chart
                    VStack(spacing: 2) {
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                ForEach(breakdown, id: \.category) { item in
                                    let fraction = CGFloat(item.size) / CGFloat(total)
                                    if fraction > 0.005 {
                                        Rectangle()
                                            .fill(item.category.color)
                                            .frame(width: geo.size.width * fraction)
                                    }
                                }
                            }
                        }
                        .frame(height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }

                    // Legend
                    ForEach(breakdown, id: \.category) { item in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(item.category.color)
                                .frame(width: 10, height: 10)
                            Image(systemName: item.category.sfSymbol)
                                .frame(width: 16)
                                .foregroundStyle(.secondary)
                            Text(item.category.displayName)
                            Spacer()
                            Text(ByteFormatter.string(from: item.size))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }

                Divider()

                // Actions
                Button {
                    NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
                } label: {
                    Label("Reveal in Finder", systemImage: "arrow.right.circle")
                }
                .buttonStyle(.bordered)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.path, forType: .string)
                } label: {
                    Label("Copy Path", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .task(id: node.id) {
            breakdown = []
            guard node.isDirectory else { return }
            // Walks the whole subtree (millions of nodes for a volume root); keep it off the main actor.
            let node = node
            let result = await Task.detached(priority: .userInitiated) {
                node.categoryBreakdown()
            }.value
            if !Task.isCancelled { breakdown = result }
        }
    }

    private var attributeNotes: [String] {
        let attributes = node.attributes
        var notes: [String] = []
        if attributes.contains(.symlink) { notes.append("Symbolic link (target not followed)") }
        if attributes.contains(.hidden) { notes.append("Hidden") }
        if attributes.contains(.sparse) { notes.append("Sparse file: unwritten regions use no disk space") }
        if attributes.contains(.compressed) { notes.append("Compressed by the file system") }
        if attributes.contains(.clone) {
            if !attributes.contains(.cloneOwner) && node.cloneID != 0 {
                notes.append("APFS clone: shared blocks are counted on another copy")
            } else {
                notes.append("APFS clone: shares blocks with other files")
            }
        }
        if attributes.contains(.hardLinked) { notes.append("Has multiple hard links; counted once") }
        if attributes.contains(.purgeable) { notes.append("Purgeable: macOS may remove it when space is needed") }
        return notes
    }
}
