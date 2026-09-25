import SwiftUI

struct DetailPanelView: View {
    let node: FileNode
    let results: ResultsModel
    let sizeMetric: SizeMetric

    @State private var breakdown: CategoryBreakdown = []

    var body: some View {
        Form {
            Section {
                header
            }

            Section {
                LabeledContent("Logical size", value: ByteFormatter.string(from: node.totalSize))
                LabeledContent("Physical size", value: ByteFormatter.string(from: node.totalAllocatedSize))
                if node.isDirectory {
                    LabeledContent("Files", value: node.fileCount.formatted())
                    LabeledContent("Folders", value: node.directoryCount.formatted())
                }
                if let date = node.modificationDate {
                    LabeledContent("Modified", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                if !attributeNotes.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(attributeNotes, id: \.self) { note in
                            Label(note, systemImage: "info.circle")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()

            if node.isDirectory && !breakdown.isEmpty {
                Section("By Category") {
                    CategoryBar(breakdown: breakdown)
                    ForEach(breakdown, id: \.category) { item in
                        LabeledContent {
                            Text(ByteFormatter.string(from: item.size))
                                .monospacedDigit()
                        } label: {
                            Label {
                                Text(item.category.displayName)
                            } icon: {
                                Circle()
                                    .fill(item.category.color)
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                }
            }

            Section {
                VStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Text("Reveal in Finder")
                            .frame(maxWidth: .infinity)
                    }
                    .prominentGlassButtonStyle()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.path, forType: .string)
                    } label: {
                        Text("Copy Path")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButtonStyle()
                }
                .controlSize(.large)
            }
        }
        .formStyle(.grouped)
        .task(id: node) {
            breakdown = []
            guard node.isDirectory else { return }
            let result = await results.categoryBreakdown(of: node)
            if !Task.isCancelled { breakdown = result }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: node.isDirectory ? "folder.fill" : node.category.sfSymbol)
                    .font(.title2)
                    .foregroundStyle(.black.opacity(0.7))
                    .frame(width: 40, height: 40)
                    .background(node.category.color, in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(node.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text(node.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(ByteFormatter.string(from: node.size(for: sizeMetric)))
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.3)
                    .monospacedDigit()
                Text(shareDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var shareDescription: String {
        let metricName = sizeMetric == .allocatedSize ? "physical size" : "logical size"
        // The share of the folder the treemap shows.
        let viewRoot = results.viewRoot
        guard viewRoot !== node else { return metricName.capitalized }
        let total = viewRoot.size(for: sizeMetric)
        guard total > 0 else { return metricName.capitalized }
        let share = (Double(node.size(for: sizeMetric)) / Double(total)).formatted(.percent.precision(.fractionLength(1)))
        return "\(share) of \(viewRoot.name) · \(metricName)"
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

/// Stacked bar of category shares; slivers under half a percent are dropped.
private struct CategoryBar: View {
    let breakdown: CategoryBreakdown

    var body: some View {
        let total = max(1, breakdown.reduce(0) { $0 + $1.size })
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(breakdown, id: \.category) { item in
                    let fraction = CGFloat(item.size) / CGFloat(total)
                    if fraction > 0.005 {
                        Rectangle()
                            .fill(item.category.color)
                            .frame(width: max(2, geometry.size.width * fraction - 2))
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(.capsule)
        .accessibilityHidden(true)
    }
}
