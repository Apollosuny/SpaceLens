import SwiftUI

struct ScanProgressView: View {
    let progress: ScanProgressSnapshot
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 320)
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .padding(.bottom, 8)
            }

            Text(title)
                .font(.title2.bold())

            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    Label {
                        Text("\(progress.fileCount.formatted()) files")
                    } icon: {
                        Image(systemName: "doc.fill")
                    }

                    Label {
                        Text("\(progress.directoryCount.formatted()) folders")
                    } icon: {
                        Image(systemName: "folder.fill")
                    }

                    Label {
                        Text(ByteFormatter.string(from: progress.physicalBytes))
                    } icon: {
                        Image(systemName: "internaldrive.fill")
                    }
                }
                .font(.title3)
                .monospacedDigit()

                Text(progress.currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)

                HStack(spacing: 12) {
                    Text(elapsed)
                    if progress.inaccessibleCount > 0 {
                        Label("\(progress.inaccessibleCount.formatted()) folders skipped", systemImage: "lock.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            }

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var elapsed: String {
        let seconds = Date().timeIntervalSince(progress.startedAt)
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}
