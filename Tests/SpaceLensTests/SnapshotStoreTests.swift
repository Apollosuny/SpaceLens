import Foundation
import Testing
@testable import SpaceLens

@Suite("Snapshot persistence")
struct SnapshotStoreTests {
    private func makeReport(rootPath: String, options: ScanOptions = ScanOptions()) -> ScanReport {
        ScanReport(
            rootPath: rootPath, options: options, kind: .full, startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 1.5, fileCount: 1, directoryCount: 1, logicalSize: 1, physicalSize: 1,
            inaccessiblePaths: ["/locked"], inaccessibleCount: 3
        )
    }

    @Test("Codec round-trips every node field")
    func codecRoundTrip() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("docs/report.pdf", bytes: 5_000)
        try fixture.writeFile(".hidden/ünïcödé 文件.txt", bytes: 300)
        try fixture.writeSparseFile("sparse", logicalBytes: 8 * 1024 * 1024)
        try fixture.writeFile("original", bytes: 50_000)
        try fixture.clone("clone", from: "original")
        try fixture.symlink("link", to: "docs")
        let (root, _) = try await fixture.scan()

        let decoded = try SnapshotCodec.decode(try SnapshotCodec.encode(root))

        #expect(decoded.structure() == root.structure())
        #expect(decoded.fileCount == root.fileCount)
        #expect(decoded.directoryCount == root.directoryCount)
        #expect(decoded.totalSize == root.totalSize)
        for relative in ["docs/report.pdf", ".hidden/ünïcödé 文件.txt", "sparse", "original", "clone", "link"] {
            let original = try #require(root.descendant(relative))
            let copy = try #require(decoded.descendant(relative))
            #expect(copy.attributes == original.attributes)
            #expect(copy.category == original.category)
            #expect(copy.fileID == original.fileID)
            #expect(copy.cloneID == original.cloneID)
            #expect(copy.ownSize == original.ownSize)
            #expect(copy.modificationTime == original.modificationTime)
            #expect(copy.path == original.path)
        }
    }

    @Test("Corrupt payloads are rejected")
    func corruptPayload() throws {
        let root = FileNode(name: "/r", fileID: 1, attributes: .directory)
        root.setChildren([FileNode(name: "f", fileID: 2, attributes: [], ownSize: 10, allocatedSize: 4096)])
        let valid = try SnapshotCodec.encode(root)
        let payload = try (valid as NSData).decompressed(using: .lz4) as Data
        let truncated = try (payload.prefix(payload.count - 2) as NSData).compressed(using: .lz4) as Data

        #expect(throws: (any Error).self) { try SnapshotCodec.decode(truncated) }
        #expect(throws: (any Error).self) { try SnapshotCodec.decode(Data("garbage".utf8)) }
    }

    @Test("Store saves privately and loads only matching snapshots")
    func storeRoundTrip() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("data/file", bytes: 1_000)
        let (root, _) = try await fixture.scan()
        let storeFixture = try Fixture()
        let store = ScanSnapshotStore(directory: URL(filePath: storeFixture.path("Snapshots")))
        let checkpoint = ChangeJournal.Checkpoint(eventID: 42, journalUUID: "UUID")
        let metadata = ScanSnapshot.Metadata(
            rootPath: fixture.root, options: ScanOptions(), checkpoint: checkpoint,
            report: makeReport(rootPath: fixture.root)
        )

        try store.save(ScanSnapshot(metadata: metadata, root: root))

        let loaded = try #require(try store.load(rootPath: fixture.root, options: ScanOptions()))
        #expect(loaded.metadata.checkpoint == checkpoint)
        #expect(loaded.metadata.report == metadata.report)
        #expect(loaded.root.structure() == root.structure())
        #expect(try store.load(rootPath: fixture.root, options: ScanOptions(includeHiddenFiles: false)) == nil)
        #expect(try store.load(rootPath: fixture.path("other"), options: ScanOptions()) == nil)

        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path + "/" + files[0])
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        try store.removeAll()
        #expect(try store.load(rootPath: fixture.root, options: ScanOptions()) == nil)
    }

    @Test("History keeps newest entries first and trims to the limit")
    func history() throws {
        let fixture = try Fixture()
        let store = ScanHistoryStore(fileURL: URL(filePath: fixture.path("History/history.json")))
        #expect(try store.load().isEmpty)

        for index in 0..<(ScanHistoryStore.maxEntries + 5) {
            try store.append(ScanHistoryEntry(
                completedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                report: makeReport(rootPath: "/root\(index)")
            ))
        }

        let history = try store.load()
        #expect(history.count == ScanHistoryStore.maxEntries)
        #expect(history.first?.rootPath == "/root\(ScanHistoryStore.maxEntries + 4)")
        try store.removeAll()
        #expect(try store.load().isEmpty)
    }
}
