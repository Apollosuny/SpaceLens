import Foundation
import Testing
@testable import SpaceLens

@Suite("ScanScope")
struct ScanScopeTests {
    private let firmlinks = Firmlink.parse("""
    /Users\tUsers
    /Applications\tApplications
    /System/Library/Caches\tSystem/Library/Caches

    malformed line
    """)

    private func directoryEntry(_ name: String, mountBoundary: Bool = false) -> DirectoryEntry {
        DirectoryEntry(
            name: name, kind: .directory, fileID: 1, bsdFlags: 0, modificationTime: 0,
            isMountBoundary: mountBoundary, linkCount: 1, logicalSize: 0, allocatedSize: 0,
            privateSize: nil, cloneID: nil, extendedFlags: 0
        )
    }

    @Test("Parses the firmlinks list, ignoring malformed lines")
    func parsesFirmlinks() {
        #expect(firmlinks == [
            Firmlink(path: "/Users", dataVolumeRelativePath: "Users"),
            Firmlink(path: "/Applications", dataVolumeRelativePath: "Applications"),
            Firmlink(path: "/System/Library/Caches", dataVolumeRelativePath: "System/Library/Caches"),
        ])
    }

    @Test("Scanning / enters the Data volume but skips its firmlinked directories")
    func bootVolumePolicy() {
        let scope = ScanScope(rootPath: "/", options: ScanOptions(), firmlinks: firmlinks)

        #expect(scope.shouldDescend(into: directoryEntry("Data", mountBoundary: true), atPath: "/System/Volumes/Data"))
        #expect(!scope.shouldDescend(into: directoryEntry("VM", mountBoundary: true), atPath: "/System/Volumes/VM"))
        #expect(!scope.shouldDescend(into: directoryEntry("Users"), atPath: "/System/Volumes/Data/Users"))
        #expect(!scope.shouldDescend(into: directoryEntry("Caches"), atPath: "/System/Volumes/Data/System/Library/Caches"))
        #expect(scope.shouldDescend(into: directoryEntry("private"), atPath: "/System/Volumes/Data/private"))
        #expect(scope.shouldDescend(into: directoryEntry("Users"), atPath: "/Users"))
    }

    @Test("Folder scans never cross mount points")
    func folderPolicy() {
        let scope = ScanScope(rootPath: "/Volumes/External", options: ScanOptions(), firmlinks: firmlinks)

        #expect(!scope.shouldDescend(into: directoryEntry("mnt", mountBoundary: true), atPath: "/Volumes/External/mnt"))
        #expect(scope.shouldDescend(into: directoryEntry("Users"), atPath: "/Volumes/External/Users"))
    }

    @Test("FSEvents paths are mapped back through firmlinks and filtered to the root")
    func normalizesJournalPaths() {
        let rootNormalizer = PathNormalizer(rootPath: "/", firmlinks: firmlinks)
        #expect(rootNormalizer.normalize("/System/Volumes/Data/Users/me/Documents") == "/Users/me/Documents")
        #expect(rootNormalizer.normalize("/System/Volumes/Data/Users") == "/Users")
        #expect(rootNormalizer.normalize("/System/Volumes/Data/private/tmp") == "/System/Volumes/Data/private/tmp")
        #expect(rootNormalizer.normalize("/Users/me/") == "/Users/me")

        let folderNormalizer = PathNormalizer(rootPath: "/Users/me", firmlinks: firmlinks)
        #expect(folderNormalizer.normalize("/System/Volumes/Data/Users/me/Downloads") == "/Users/me/Downloads")
        #expect(folderNormalizer.normalize("/Users/me") == "/Users/me")
        #expect(folderNormalizer.normalize("/Users/meow") == nil)
        #expect(folderNormalizer.normalize("/Applications") == nil)
    }
}
