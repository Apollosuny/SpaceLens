import SwiftUI

struct VolumeInfo: Identifiable {
    let id: URL
    let url: URL
    let name: String
    let isInternal: Bool
    let totalBytes: Int64
    let availableBytes: Int64

    var path: String { url.path(percentEncoded: false) }
    var usedBytes: Int64 { totalBytes - availableBytes }
    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
}

struct WelcomeView: View {
    let history: [ScanHistoryEntry]
    @Binding var includeHiddenFiles: Bool
    let onVolumeSelected: (String) -> Void
    let onClearHistory: () -> Void
    /// Shown as "Back to Results" when a finished scan is still loaded.
    var onReturnToResults: (() -> Void)?

    @State private var volumes: [VolumeInfo] = []
    @State private var isDropTargeted = false

    private static let maxRecentScans = 5

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                header

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Disks")
                    if volumes.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(24)
                            .insetGroupBackground()
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(volumes.enumerated()), id: \.element.id) { index, volume in
                                if index > 0 { Divider().padding(.leading, 72) }
                                VolumeRow(
                                    volume: volume,
                                    lastScan: lastScan(of: volume),
                                    isPrimary: index == 0
                                ) {
                                    onVolumeSelected(volume.path)
                                }
                            }
                        }
                        .insetGroupBackground()
                    }

                    HStack(spacing: 12) {
                        Button("Scan a Folder…") {
                            if let path = FolderPicker.chooseFolder() { onVolumeSelected(path) }
                        }
                            .glassButtonStyle()
                        Text("or drop a folder on this window")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Toggle("Include hidden files", isOn: $includeHiddenFiles)
                            .toggleStyle(.checkbox)
                            .help("Hidden files still use disk space. Turn off to see only what Finder shows.")
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }

                if !recentScans.isEmpty {
                    RecentScansSection(
                        entries: recentScans,
                        onSelect: { onVolumeSelected($0.rootPath) },
                        onClear: onClearHistory
                    )
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            onVolumeSelected(folder.path(percentEncoded: false))
            return true
        } isTargeted: { isDropTargeted = $0 }
        .onAppear { loadVolumes() }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("See what’s using your disk.")
                .font(.system(size: 40, weight: .semibold))
                .tracking(-0.28)
            Text("Choose a disk or folder. Rescans only re-read what changed.")
                .font(.system(size: 17))
                .tracking(-0.374)
                .foregroundStyle(.secondary)
            if let onReturnToResults {
                Button("Back to Results", systemImage: "chevron.left", action: onReturnToResults)
                    .buttonStyle(.link)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
    }

    /// Most recent scan per root, newest first.
    private var recentScans: [ScanHistoryEntry] {
        var seenRoots = Set<String>()
        return history
            .filter { seenRoots.insert($0.rootPath).inserted }
            .prefix(Self.maxRecentScans)
            .map { $0 }
    }

    private func lastScan(of volume: VolumeInfo) -> Date? {
        let path = volume.path.count > 1 && volume.path.hasSuffix("/") ? String(volume.path.dropLast()) : volume.path
        return history.first { $0.rootPath == path }?.completedAt
    }

    private func loadVolumes() {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
            .volumeIsBrowsableKey
        ]

        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) else { return }

        volumes = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let name = values.volumeName,
                  let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity
            else { return nil }

            return VolumeInfo(
                id: url,
                url: url,
                name: name,
                isInternal: values.volumeIsInternal ?? false,
                totalBytes: Int64(total),
                availableBytes: Int64(available)
            )
        }
    }
}

/// The system folder picker, shared by the welcome screen and the Open Folder command.
@MainActor
enum FolderPicker {
    static func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder to scan"
        panel.prompt = "Scan"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path(percentEncoded: false)
    }
}

// MARK: - Inset Group

private struct SectionTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
    }
}

private extension View {
    /// A System Settings–style inset group: content surface, hairline edge, no shadow.
    func insetGroupBackground() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator, lineWidth: 0.5))
    }
}

// MARK: - Volume Row

private struct VolumeRow: View {
    let volume: VolumeInfo
    let lastScan: Date?
    let isPrimary: Bool
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            UsageRing(fraction: volume.usedFraction, color: usageColor)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(volume.name)
                        .fontWeight(.semibold)
                    Text(volume.isInternal ? "Internal" : "External")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if isPrimary {
                Button("Scan", action: onScan)
                    .prominentGlassButtonStyle()
                    .buttonBorderShape(.capsule)
            } else {
                Button("Scan", action: onScan)
                    .glassButtonStyle()
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var detail: String {
        var parts = [
            "\(ByteFormatter.string(from: volume.usedBytes)) used of \(ByteFormatter.string(from: volume.totalBytes))",
            "\(ByteFormatter.string(from: volume.availableBytes)) available"
        ]
        if let lastScan {
            parts.append("scanned \(lastScan.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    private var usageColor: Color {
        if volume.usedFraction > 0.9 { return .red }
        if volume.usedFraction > 0.75 { return .orange }
        return .accentColor
    }
}

private struct UsageRing: View {
    let fraction: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(fraction, format: .percent.precision(.fractionLength(0)))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .padding(2.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Int((fraction * 100).rounded())) percent used"))
    }
}

// MARK: - Recent Scans

private struct RecentScansSection: View {
    let entries: [ScanHistoryEntry]
    let onSelect: (ScanHistoryEntry) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Recent Scans")
                Spacer()
                Button("Clear History", action: onClear)
                    .buttonStyle(.link)
                    .help("Remove scan history and cached scan results")
                    .padding(.horizontal, 12)
            }

            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 44) }
                    RecentScanRow(entry: entry) { onSelect(entry) }
                }
            }
            .insetGroupBackground()
        }
    }
}

private struct RecentScanRow: View {
    let entry: ScanHistoryEntry
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: entry.rootPath == "/" ? "internaldrive.fill" : "folder.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayName)
                        .lineLimit(1)
                    Text(entry.rootPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ByteFormatter.string(from: entry.report.physicalSize))
                        .monospacedDigit()
                    Text(entry.completedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isHovering ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Rescan \(entry.rootPath) (reuses the cached result when possible)")
    }
}
