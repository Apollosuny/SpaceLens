import SwiftUI

/// Cleanup suggestions for the whole scan, grouped by risk: what each item is, how much space it takes
/// and what removing it costs.
///
/// Sizes are always physical, whatever the size toggle says: what matters here is the disk space that
/// removing an item frees, and logical sizes of sparse files (VM and container disks) run to terabytes.
struct CleanupView: View {
    private static let sizeMetric = SizeMetric.allocatedSize

    let results: ResultsModel
    /// Switches to a chart and selects the node there.
    let onShowInChart: (FileNode) -> Void

    var body: some View {
        if let report = results.cleanupReport {
            if report.findings.isEmpty {
                ContentUnavailableView(
                    "No Cleanup Suggestions",
                    systemImage: "sparkles",
                    description: Text("Nothing here matches a known cache, build folder or old download. Scan your home folder or startup disk to find them.")
                )
            } else {
                CleanupList(report: report, results: results, sizeMetric: Self.sizeMetric, onShowInChart: onShowInChart)
            }
        } else {
            ProgressView("Analyzing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CleanupList: View {
    /// Items listed per finding; the rest are summarized.
    private static let maxListedItems = 50

    let report: CleanupReport
    let results: ResultsModel
    let sizeMetric: SizeMetric
    let onShowInChart: (FileNode) -> Void

    @State private var expandedFindings: Set<String> = []

    var body: some View {
        List(selection: selection) {
            Section {
                CleanupSummary(report: report, sizeMetric: sizeMetric)
            } footer: {
                Text("Estimated disk space each item would free. Files shared with other copies (clones, hard links) may free less.")
            }

            ForEach(CleanupRisk.allCases, id: \.self) { risk in
                let findings = report.findings(for: risk)
                if !findings.isEmpty {
                    Section {
                        ForEach(findings) { finding in
                            findingRows(finding)
                        }
                    } header: {
                        HStack {
                            Label(risk.title, systemImage: risk.sfSymbol)
                                .foregroundStyle(risk.color)
                            Spacer()
                            Text(ByteFormatter.string(from: report.totalSize(for: risk, metric: sizeMetric)))
                                .monospacedDigit()
                        }
                    } footer: {
                        if risk == .protected {
                            Text("Listed so you know where the space goes. SpaceLens never suggests removing these.")
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func findingRows(_ finding: CleanupFinding) -> some View {
        if finding.items.count == 1, let item = finding.items.first {
            CleanupFindingRow(finding: finding, sizeMetric: sizeMetric, path: item.node.path)
                .tag(item.node)
                .contextMenu { itemMenu(for: item.node) }
        } else {
            DisclosureGroup(isExpanded: isExpanded(finding)) {
                ForEach(finding.items.prefix(Self.maxListedItems), id: \.node) { item in
                    CleanupItemRow(item: item, sizeMetric: sizeMetric)
                        .tag(item.node)
                        .contextMenu { itemMenu(for: item.node) }
                }
                if finding.items.count > Self.maxListedItems {
                    Text("and \(finding.items.count - Self.maxListedItems) smaller items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } label: {
                CleanupFindingRow(finding: finding, sizeMetric: sizeMetric, path: nil)
            }
        }
    }

    @ViewBuilder
    private func itemMenu(for node: FileNode) -> some View {
        Button("Show in Treemap") { onShowInChart(node) }
        Button("Reveal in Finder") {
            NSWorkspace.shared.selectFile(node.path, inFileViewerRootedAtPath: "")
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.path, forType: .string)
        }
    }

    private var selection: Binding<FileNode?> {
        // Selecting here drives the inspector without moving the chart, which is not on screen.
        Binding(get: { results.selection }, set: { if let node = $0 { results.select(node) } })
    }

    private func isExpanded(_ finding: CleanupFinding) -> Binding<Bool> {
        Binding(
            get: { expandedFindings.contains(finding.id) },
            set: { isExpanded in
                if isExpanded { expandedFindings.insert(finding.id) } else { expandedFindings.remove(finding.id) }
            }
        )
    }
}

/// Totals per risk level, side by side.
private struct CleanupSummary: View {
    let report: CleanupReport
    let sizeMetric: SizeMetric

    var body: some View {
        HStack(spacing: 12) {
            ForEach(CleanupRisk.allCases, id: \.self) { risk in
                VStack(alignment: .leading, spacing: 4) {
                    Label(risk.title, systemImage: risk.sfSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(risk.color)
                        .lineLimit(1)
                    Text(ByteFormatter.string(from: report.totalSize(for: risk, metric: sizeMetric)))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                // A zero minimum width keeps the summary from forcing the window wider.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(risk.color.opacity(0.1), in: .rect(cornerRadius: 8))
            }
        }
        .padding(.vertical, 4)
    }
}

/// "Xcode DerivedData — 14 GB — Rebuilt automatically": what it is, its size and what removing it costs.
private struct CleanupFindingRow: View {
    let finding: CleanupFinding
    let sizeMetric: SizeMetric
    /// Shown for single-item findings, whose row stands for that item.
    let path: String?

    var body: some View {
        let rule = finding.rule
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: rule.risk.sfSymbol)
                .foregroundStyle(rule.risk.color)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(rule.title)
                        .fontWeight(.semibold)
                    if finding.items.count > 1 {
                        Text("\(finding.items.count) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(rule.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path {
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Label(rule.recovery.summary, systemImage: rule.recovery.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(ByteFormatter.string(from: finding.size(for: sizeMetric)))
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

private struct CleanupItemRow: View {
    let item: CleanupItem
    let sizeMetric: SizeMetric

    var body: some View {
        let node = item.node
        HStack(spacing: 8) {
            Image(systemName: node.isDirectory ? "folder.fill" : node.category.sfSymbol)
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(.tint) : AnyShapeStyle(node.category.color))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(node.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let date = node.modificationDate {
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(ByteFormatter.string(from: item.size(for: sizeMetric)))
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
    }
}

/// The inspector's verdict on one node.
struct CleanupVerdictView: View {
    let verdict: CleanupVerdict?

    var body: some View {
        if let verdict {
            let rule = verdict.rule
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label(rule.risk.shortTitle, systemImage: rule.risk.sfSymbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(rule.risk.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(rule.risk.color.opacity(0.15), in: .capsule)
                    Text(rule.title)
                        .fontWeight(.semibold)
                }
                if let scopeNote = scopeNote(verdict) {
                    Text(scopeNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(rule.explanation)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Label(rule.recovery.summary, systemImage: rule.recovery.sfSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } else {
            Text("No guidance. Keep it unless you know what it is.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func scopeNote(_ verdict: CleanupVerdict) -> String? {
        switch verdict.scope {
        case .item: nil
        case .container: "Each item inside is listed separately in Cleanup."
        case .inside(let item): "Part of \(item.name)"
        }
    }
}

extension CleanupRecovery {
    var sfSymbol: String {
        switch self {
        case .regenerated: "arrow.triangle.2.circlepath"
        case .redownloaded: "icloud.and.arrow.down"
        case .notRecoverable: "exclamationmark.circle"
        }
    }
}
