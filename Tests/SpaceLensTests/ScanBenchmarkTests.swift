import Foundation
import SwiftUI
import Testing
@testable import SpaceLens

/// Opt-in benchmark against a real directory:
/// `SPACELENS_BENCHMARK_PATH=/some/path swift test --filter ScanBenchmarkTests`
@Suite("Scan benchmark", .enabled(if: ProcessInfo.processInfo.environment["SPACELENS_BENCHMARK_PATH"] != nil))
struct ScanBenchmarkTests {
    @Test("Full scan, snapshot round-trip and no-op incremental update")
    func benchmark() async throws {
        let path = ScanScope.canonicalPath(try #require(ProcessInfo.processInfo.environment["SPACELENS_BENCHMARK_PATH"]))
        let clock = ContinuousClock()
        let scope = ScanScope(rootPath: path, options: ScanOptions())

        var root: FileNode?
        var context: ScanContext?
        let scanTime = try await clock.measure {
            context = ScanContext(scope: scope, progress: ScanProgress())
            root = try await DatalessMaterializationPolicy.withMaterializationDisabled {
                try await FileScanner(context: context!).scanRoot()
            }
        }
        let tree = try #require(root)

        var encoded = Data()
        let encodeTime = try clock.measure { encoded = try SnapshotCodec.encode(tree) }
        var decoded: FileNode?
        let decodeTime = try clock.measure { decoded = try SnapshotCodec.decode(encoded) }

        let incrementalContext = ScanContext(scope: scope, progress: ScanProgress())
        let incrementalTime = try await clock.measure {
            _ = try await IncrementalScanner(scanner: FileScanner(context: incrementalContext))
                .apply(ChangeSet(directories: [path]), to: try #require(decoded))
        }

        let bounds = TreemapRect(x: 0, y: 0, width: 1400, height: 900)
        var items: [TreemapItem] = []
        let layoutTime = clock.measure {
            items = TreemapLayoutEngine().layout(root: tree, in: bounds, sizeMetric: .allocatedSize)
        }
        let hitTester = TreemapHitTester(items: items)
        let hitTestTime = clock.measure {
            for step in 0..<100 {
                _ = hitTester.itemAt(point: CGPoint(x: Double(step) * 14, y: Double(step) * 9))
            }
        }

        let drawnItems = items
        func measureDraw(_ drawItems: [TreemapItem], labels: Bool) async -> Duration {
            await MainActor.run {
                // Best of several runs; each needs a fresh renderer because ImageRenderer caches its image.
                (0..<5).map { _ in
                    let renderer = ImageRenderer(content: Canvas { context, size in
                        TreemapRenderer(items: drawItems, selectedItemID: nil, zoomScale: 1,
                                        panOffset: .zero, showLabels: labels, sizeMetric: .allocatedSize)
                            .draw(in: &context, size: size)
                    }.frame(width: 1400, height: 900))
                    return clock.measure { _ = renderer.cgImage }
                }.min()!
            }
        }
        let emptyDrawTime = await measureDraw([], labels: false)
        let noLabelDrawTime = await measureDraw(drawnItems, labels: false)
        let drawTime = await measureDraw(drawnItems, labels: true)

        print("""
          treemap draw (1 frame): \(drawTime), without labels \(noLabelDrawTime), empty \(emptyDrawTime)
          treemap layout: \(layoutTime) → \(items.count) items; 100 hit tests: \(hitTestTime)
        [benchmark] \(path)
          files: \(tree.fileCount)  directories: \(tree.directoryCount)  skipped: \(context!.inaccessible.count)
          logical: \(ByteFormatter.string(from: tree.totalSize))  physical: \(ByteFormatter.string(from: tree.totalAllocatedSize))
          full scan: \(scanTime)
          snapshot: \(encoded.count / 1_048_576) MB, encode \(encodeTime), decode+finalize \(decodeTime)
          incremental (1 dir): \(incrementalTime)
          resident memory: \(Self.residentMegabytes()) MB
        """)
    }

    private static func residentMegabytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size / 1_048_576 : 0
    }
}
