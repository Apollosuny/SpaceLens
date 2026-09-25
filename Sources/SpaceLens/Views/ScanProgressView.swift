import SwiftUI

/// Reads the sampled progress itself, so its 10 Hz updates re-render only this view.
struct ScanProgressView: View {
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        if let progress = appState.scanProgress {
            ScanProgressContent(progress: progress, onCancel: onCancel)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ScanProgressContent: View {
    let progress: ScanProgressSnapshot
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            ProgressRing(fraction: progress.fractionCompleted, physicalBytes: progress.physicalBytes, estimatedTotalBytes: progress.estimatedTotalBytes)
                .frame(width: 240, height: 240)

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                    .tracking(0.231)
                Text(progress.currentPath.isEmpty ? " " : progress.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 0) {
                StatCell(value: Text(progress.fileCount.formatted()), label: "Files")
                Divider()
                StatCell(value: Text(progress.directoryCount.formatted()), label: "Folders")
                Divider()
                // A system-driven timer: progress snapshots stop changing while counters are idle (loading the cache,
                // finalizing), so a value computed from them would freeze.
                StatCell(value: Text(timerInterval: progress.startedAt...Date.distantFuture, countsDown: false), label: "Elapsed")
            }
            .frame(width: 456, height: 60)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.separator, lineWidth: 0.5))

            if progress.inaccessibleCount > 0 {
                Label {
                    Text("\(progress.inaccessibleCount.formatted()) folders skipped — no permission to read them")
                } icon: {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .glassButtonStyle()
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var title: String {
        switch progress.phase {
        case .preparing: "Preparing…"
        case .loadingCache: "Loading Previous Scan…"
        case .applyingChanges(let count): "Updating \(count.formatted()) Changed Folders…"
        case .scanning: "Scanning…"
        case .finalizing: "Finalizing…"
        }
    }
}

/// Determinate ring while the total is known; otherwise a spinner with the bytes counted so far.
private struct ProgressRing: View {
    let fraction: Double?
    let physicalBytes: Int64
    let estimatedTotalBytes: Int64?

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 12)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: fraction)
            }

            VStack(spacing: 2) {
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 56, weight: .semibold))
                        .tracking(-0.28)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.bottom, 8)
                }
                Text(bytesLabel)
                    .foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .padding(6)
    }

    private var bytesLabel: String {
        let counted = ByteFormatter.string(from: physicalBytes)
        guard fraction != nil, let estimatedTotalBytes else { return counted }
        return "\(counted) of \(ByteFormatter.string(from: estimatedTotalBytes))"
    }
}

private struct StatCell: View {
    let value: Text
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 2) {
            value
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.374)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
