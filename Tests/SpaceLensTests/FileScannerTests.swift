import Darwin
import Foundation
import Testing
@testable import SpaceLens

@Suite("FileScanner")
struct FileScannerTests {
    @Test("Directory entries match lstat")
    func directoryReaderMatchesLstat() throws {
        let fixture = try Fixture()
        try fixture.writeFile("a.bin", bytes: 10_000)
        try fixture.writeFile(".hidden", bytes: 100)
        try fixture.makeDirectory("sub")
        try fixture.symlink("link", to: "a.bin")

        let entries = try DirectoryReader.readEntries(atPath: fixture.root)
        #expect(Set(entries.map(\.name)) == ["a.bin", ".hidden", "sub", "link"])

        for entry in entries {
            var info = stat()
            #expect(lstat(fixture.path(entry.name), &info) == 0)
            #expect(entry.fileID == UInt64(info.st_ino))
            #expect(entry.modificationTime == Int64(info.st_mtimespec.tv_sec))
            if entry.kind == .regularFile {
                #expect(entry.logicalSize == Int64(info.st_size))
                #expect(entry.allocatedSize == Int64(info.st_blocks) * 512)
            }
        }
        #expect(entries.first { $0.name == "sub" }?.kind == .directory)
        #expect(entries.first { $0.name == "link" }?.kind == .symlink)
        #expect(entries.first { $0.name == ".hidden" }?.isHidden == true)
    }

    @Test("Builds the tree with correct aggregates")
    func buildsTree() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("a.txt", bytes: 1_000)
        try fixture.writeFile("dir/b.jpg", bytes: 20_000)
        try fixture.writeFile("dir/nested/c.mp4", bytes: 50_000)

        let (root, context) = try await fixture.scan()

        #expect(root.name == fixture.root)
        #expect(root.fileCount == 3)
        #expect(root.directoryCount == 3)
        #expect(root.totalSize == 71_000)
        let expectedPhysical = ["a.txt", "dir/b.jpg", "dir/nested/c.mp4"].reduce(0) { $0 + fixture.allocatedBytes($1) }
        #expect(root.totalAllocatedSize == expectedPhysical)
        #expect(root.descendant("dir/nested/c.mp4")?.category == .video)
        #expect(root.descendant("dir/nested/c.mp4")?.path == fixture.path("dir/nested/c.mp4"))
        #expect(root.directoryChildren.map(\.name) == ["dir"])
        #expect(root.children.first?.name == "dir", "children are sorted by size, largest first")
        #expect(context.inaccessible.count == 0)
    }

    @Test("Hidden files are included by default and excluded on request")
    func hiddenFiles() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("visible", bytes: 1_000)
        try fixture.writeFile(".dotfile", bytes: 2_000)
        try fixture.writeFile(".hiddenDir/inner", bytes: 4_000)
        try fixture.writeFile("flagged", bytes: 8_000)
        #expect(chflags(fixture.path("flagged"), UInt32(UF_HIDDEN)) == 0)

        let (included, _) = try await fixture.scan()
        #expect(included.totalSize == 15_000)
        #expect(included.child(named: ".dotfile")?.attributes.contains(.hidden) == true)
        #expect(included.child(named: "flagged")?.attributes.contains(.hidden) == true)

        let (excluded, _) = try await fixture.scan(options: ScanOptions(includeHiddenFiles: false))
        #expect(excluded.totalSize == 1_000)
        #expect(excluded.children.map(\.name) == ["visible"])
    }

    @Test("Symlinks are recorded as leaves and never followed, so loops terminate")
    func symlinkLoops() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("dir/file", bytes: 1_000)
        try fixture.symlink("dir/parent", to: "..")
        try fixture.symlink("dir/self", to: "self")
        try fixture.symlink("root", to: fixture.root)

        let (root, _) = try await fixture.scan()

        let parentLink = try #require(root.descendant("dir/parent"))
        #expect(parentLink.attributes.contains(.symlink))
        #expect(!parentLink.isDirectory)
        #expect(root.descendant("dir/self")?.attributes.contains(.symlink) == true)
        #expect(root.directoryCount == 2)
        #expect(root.fileCount == 4)
    }

    @Test("Hard-linked files are counted once")
    func hardLinks() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("a/original", bytes: 100_000)
        try fixture.makeDirectory("b")
        try fixture.hardLink("b/link", to: "a/original")

        let (root, _) = try await fixture.scan()

        #expect(root.fileCount == 1)
        #expect(root.totalSize == 100_000)
        let survivors = [root.descendant("a/original"), root.descendant("b/link")].compactMap { $0 }
        #expect(survivors.count == 1)
        #expect(survivors.first?.attributes.contains(.hardLinked) == true)
    }

    @Test("Pure APFS clones share one physical charge")
    func clones() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("original", bytes: 1_000_000)
        try fixture.clone("copy1", from: "original")
        try fixture.clone("copy2", from: "original")

        let (root, _) = try await fixture.scan()

        let files = ["original", "copy1", "copy2"].compactMap { root.child(named: $0) }
        #expect(files.count == 3)
        #expect(files.allSatisfy { $0.attributes.contains(.clone) })
        #expect(files.filter { $0.attributes.contains(.cloneOwner) }.count == 1)
        #expect(root.totalSize == 3_000_000, "logical size counts every copy")
        #expect(root.totalAllocatedSize == fixture.allocatedBytes("original"), "physical size counts shared blocks once")
    }

    @Test("Sparse files report their allocated size")
    func sparseFiles() async throws {
        let fixture = try Fixture()
        try fixture.writeSparseFile("sparse.img", logicalBytes: 64 * 1024 * 1024)

        let (root, _) = try await fixture.scan()

        let file = try #require(root.child(named: "sparse.img"))
        #expect(file.ownSize == 64 * 1024 * 1024)
        #expect(file.allocatedSize < 1024 * 1024)
        #expect(file.attributes.contains(.sparse))
    }

    @Test("Unreadable folders are skipped and reported", .enabled(if: getuid() != 0, "root bypasses permissions"))
    func inaccessibleFolders() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("open/file", bytes: 1_000)
        try fixture.writeFile("locked/secret", bytes: 1_000)
        fixture.setPermissions("locked", 0o000)

        let (root, context) = try await fixture.scan()

        #expect(root.totalSize == 1_000)
        #expect(root.child(named: "locked")?.children.isEmpty == true)
        #expect(context.inaccessible.count == 1)
        #expect(context.inaccessible.paths == [fixture.path("locked")])
    }

    @Test("Missing or non-directory roots fail with a descriptive error")
    func invalidRoots() async throws {
        let fixture = try Fixture()
        let filePath = try fixture.writeFile("file", bytes: 10)

        await #expect(throws: ScanError.rootNotFound(fixture.path("missing"))) {
            let scope = ScanScope(rootPath: fixture.path("missing"), options: ScanOptions(), firmlinks: [])
            _ = try await FileScanner(context: ScanContext(scope: scope, progress: ScanProgress())).scanRoot()
        }
        await #expect(throws: ScanError.rootNotDirectory(filePath)) {
            let scope = ScanScope(rootPath: filePath, options: ScanOptions(), firmlinks: [])
            _ = try await FileScanner(context: ScanContext(scope: scope, progress: ScanProgress())).scanRoot()
        }
    }

    @Test("Cancellation stops the scan with CancellationError")
    func cancellation() async throws {
        let fixture = try Fixture()
        for index in 0..<20 {
            try fixture.writeFile("dir\(index)/file", bytes: 10)
        }
        let context = fixture.makeContext()
        let task = Task { try await FileScanner(context: context).scanRoot() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("Progress counters reflect the scanned tree")
    func progress() async throws {
        let fixture = try Fixture()
        try fixture.writeFile("a", bytes: 1_000)
        try fixture.writeFile("d/b", bytes: 2_000)

        let (root, context) = try await fixture.scan()
        let snapshot = context.progress.snapshot()

        #expect(snapshot.fileCount == root.fileCount)
        #expect(snapshot.directoryCount == root.directoryCount)
        #expect(snapshot.logicalBytes == root.totalSize)
        #expect(snapshot.physicalBytes == root.totalAllocatedSize)
        #expect(snapshot.phase == .finalizing)
    }
}
