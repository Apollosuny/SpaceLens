import Foundation
import Testing
@testable import SpaceLens

@Suite("IncrementalScanner")
struct IncrementalScannerTests {
    /// Scans, round-trips through the snapshot codec (as the cache does), mutates, applies `changes`,
    /// and returns the updated tree next to a fresh full scan.
    private func applyAfterMutation(
        _ fixture: Fixture,
        mutate: () throws -> Void,
        changes: (Fixture) -> ChangeSet
    ) async throws -> (updated: FileNode?, expected: FileNode) {
        let (initial, _) = try await fixture.scan()
        let cached = try SnapshotCodec.decode(try SnapshotCodec.encode(initial))
        try mutate()

        let scanner = IncrementalScanner(scanner: FileScanner(context: fixture.makeContext()))
        let updated = try await scanner.apply(changes(fixture), to: cached)
        let (expected, _) = try await fixture.scan()
        return (updated, expected)
    }

    @Test("Re-listing changed directories matches a full rescan")
    func relistMatchesFullScan() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("keep/unchanged", bytes: 10_000)
        try fixture.writeFile("keep/deep/unchanged", bytes: 10_000)
        try fixture.writeFile("grow/file", bytes: 1_000)
        try fixture.writeFile("gone/file", bytes: 5_000)
        try fixture.writeFile("edit/old", bytes: 1_000)

        let (updated, expected) = try await applyAfterMutation(fixture) {
            try fixture.writeFile("grow/file", bytes: 90_000)
            try fixture.remove("gone")
            try fixture.remove("edit/old")
            try fixture.writeFile("edit/new", bytes: 3_000)
            try fixture.writeFile("fresh/nested/file", bytes: 7_000)
        } changes: { fixture in
            ChangeSet(directories: [fixture.root, fixture.path("grow"), fixture.path("gone"), fixture.path("edit"),
                                    fixture.path("fresh"), fixture.path("fresh/nested")])
        }

        let tree = try #require(updated)
        #expect(tree.structure() == expected.structure())
        #expect(tree.totalSize == expected.totalSize)
        #expect(tree.fileCount == expected.fileCount)
        #expect(tree.child(named: "gone") == nil)
        #expect(tree.descendant("fresh/nested/file")?.ownSize == 7_000)
    }

    @Test("Unchanged subtrees are reused, not rescanned")
    func reusesUnchangedSubtrees() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("keep/file", bytes: 1_000)
        try fixture.writeFile("other/file", bytes: 1_000)
        let (initial, _) = try await fixture.scan()
        let cached = try SnapshotCodec.decode(try SnapshotCodec.encode(initial))
        let cachedKeep = try #require(cached.child(named: "keep"))

        try fixture.writeFile("new-file", bytes: 500)
        let context = fixture.makeContext()
        let updated = try await IncrementalScanner(scanner: FileScanner(context: context))
            .apply(ChangeSet(directories: [fixture.root]), to: cached)

        #expect(updated?.child(named: "keep") === cachedKeep)
        #expect(updated?.child(named: "new-file")?.ownSize == 500)
        #expect(context.progress.snapshot().directoryCount == 1, "only the root was re-read")
    }

    @Test("Recursive changes rescan the whole subtree")
    func recursiveChanges() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("tree/a/file", bytes: 1_000)

        let (updated, expected) = try await applyAfterMutation(fixture) {
            try fixture.writeFile("tree/a/b/c/deep", bytes: 40_000)
            try fixture.writeFile("tree/a/file", bytes: 2_000)
        } changes: { fixture in
            ChangeSet(recursiveDirectories: [fixture.path("tree")])
        }

        #expect(try #require(updated).structure() == expected.structure())
    }

    @Test("Paths missing from the cache resolve to their nearest cached ancestor")
    func missingPathsFallBackToAncestor() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("base/file", bytes: 1_000)

        let (updated, expected) = try await applyAfterMutation(fixture) {
            try fixture.writeFile("base/x/y/z/file", bytes: 9_000)
        } changes: { fixture in
            // Only the deepest path is reported; its ancestors are not in the cache either.
            ChangeSet(directories: [fixture.path("base/x/y/z")])
        }

        #expect(try #require(updated).structure() == expected.structure())
    }

    @Test("Hard links and clones stay de-duplicated across cached and re-listed directories")
    func deduplicationIsSeeded() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("cached/original", bytes: 200_000)
        try fixture.writeFile("cached/source", bytes: 300_000)
        try fixture.makeDirectory("relisted")
        try fixture.hardLink("relisted/link", to: "cached/original")
        try fixture.clone("relisted/clone", from: "cached/source")

        // Only one side of each link/clone pair is re-listed; which side the cached tree charged is
        // nondeterministic, and both cases must end up counted exactly once.
        let (updated, expected) = try await applyAfterMutation(fixture) {
            try fixture.writeFile("relisted/unrelated", bytes: 1_000)
        } changes: { fixture in
            ChangeSet(directories: [fixture.path("relisted")])
        }

        let tree = try #require(updated)
        #expect(tree.totalAllocatedSize == expected.totalAllocatedSize)
        #expect(tree.fileCount == expected.fileCount)
    }

    @Test("A change to the root's whole subtree requires a full scan")
    func rootRecursiveRequiresFullScan() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("file", bytes: 10)
        let (updated, _) = try await applyAfterMutation(fixture) {} changes: { fixture in
            ChangeSet(recursiveDirectories: [fixture.root])
        }
        #expect(updated == nil)
    }
}
