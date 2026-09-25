import Foundation
import Testing
@testable import SpaceLens

@Suite("CleanupAnalyzer")
struct CleanupAnalyzerTests {
    private static let homePath = "/Users/tester"
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let analyzer = CleanupAnalyzer(ruleset: .default(home: homePath), now: now)

    private func directory(_ name: String, _ children: [FileNode], modified: Date? = nil) -> FileNode {
        let node = FileNode(name: name, fileID: 0, attributes: .directory, modificationTime: Self.seconds(modified))
        for child in children { node.addChild(child) }
        return node
    }

    private func file(_ name: String, size: Int64, category: FileCategory = .documents, modified: Date? = nil) -> FileNode {
        FileNode(name: name, fileID: 0, attributes: [], category: category, ownSize: size, allocatedSize: size,
                 modificationTime: Self.seconds(modified))
    }

    private static func seconds(_ date: Date?) -> Int64 {
        date.map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    private static func daysAgo(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    /// Builds `/Users/tester` with the given entries as the scan root.
    private func home(_ children: [FileNode]) -> FileNode {
        let root = directory(Self.homePath, children)
        root.finalizeTree()
        return root
    }

    private func analyze(_ root: FileNode) throws -> CleanupReport {
        try #require(analyzer.analyze(root))
    }

    private func findingFor(_ id: String, in report: CleanupReport) -> CleanupFinding? {
        report.findings.first { $0.rule.id == id }
    }

    @Test("Xcode DerivedData is one safe item with the folder's size")
    func derivedData() throws {
        let derivedData = directory("DerivedData", [file("a", size: 700), file("b", size: 300)])
        let root = home([directory("Library", [directory("Developer", [directory("Xcode", [derivedData])])])])
        let report = try analyze(root)

        let finding = try #require(findingFor("xcode-derived-data", in: report))
        #expect(finding.rule.risk == .safe)
        #expect(finding.rule.recovery == .regenerated)
        #expect(finding.items.map(\.node) == [derivedData])
        #expect(finding.allocatedSize == 1000)
        #expect(report.totalSize(for: .safe, metric: .allocatedSize) == 1000)
    }

    @Test("The most specific rule owns a folder and sizes are never counted twice")
    func specificRuleWinsWithoutDoubleCounting() throws {
        let homebrew = directory("Homebrew", [file("bottle.tar.gz", size: 400)])
        let appCache = directory("com.example.app", [file("blob", size: 100)])
        let backup = directory("ABC-123", [file("Manifest.db", size: 250)])
        let appSupport = directory("Application Support", [
            directory("MobileSync", [directory("Backup", [backup])]),
            file("settings.plist", size: 50)
        ])
        let root = home([directory("Library", [directory("Caches", [homebrew, appCache]), appSupport])])
        let report = try analyze(root)

        #expect(findingFor("homebrew-cache", in: report)?.items.map(\.node) == [homebrew])
        #expect(findingFor("user-caches", in: report)?.items.map(\.node) == [appCache])
        #expect(findingFor("ios-backups", in: report)?.allocatedSize == 250)
        // App Support keeps only what the backup rule didn't claim.
        #expect(findingFor("app-data", in: report)?.allocatedSize == 50)
        let total = CleanupRisk.allCases.reduce(Int64(0)) { $0 + report.totalSize(for: $1, metric: .allocatedSize) }
        #expect(total == root.totalAllocatedSize)
    }

    @Test("Downloads are suggested only once they are older than 90 days")
    func oldDownloads() throws {
        let old = file("old-installer.pkg", size: 500, modified: Self.daysAgo(120))
        let recent = file("recent.pdf", size: 500, modified: Self.daysAgo(10))
        let undated = file("undated.bin", size: 500)
        let root = home([directory("Downloads", [old, recent, undated])])
        let report = try analyze(root)

        let finding = try #require(findingFor("old-downloads", in: report))
        #expect(finding.rule.risk == .review)
        #expect(finding.items.map(\.node) == [old])
    }

    @Test("File patterns skip protected areas, packages and other rules' items")
    func patternsRespectProtectionAndPackages() throws {
        let looseImage = file("Tool.dmg", size: 800)
        let recentDownloadImage = file("New.dmg", size: 300, modified: Self.daysAgo(5))
        let documentImage = file("Keep.dmg", size: 900)
        let bundledImage = file("Payload.dmg", size: 700)
        let bigVideo = file("Trip.mov", size: 2_000_000_000, category: .video)
        let smallZip = file("notes.zip", size: 1_000)
        let root = home([
            directory("Documents", [documentImage]),
            directory("Downloads", [recentDownloadImage]),
            directory("Projects", [looseImage, directory("Helper.app", [bundledImage]), smallZip]),
            directory("Movies", [bigVideo])
        ])
        let report = try analyze(root)

        let images = try #require(findingFor("disk-images", in: report))
        #expect(Set(images.items.map(\.node)) == [looseImage, recentDownloadImage])
        #expect(findingFor("large-videos", in: report)?.items.map(\.node) == [bigVideo])
        #expect(findingFor("archives", in: report) == nil)
        #expect(report.verdict(for: documentImage)?.rule.id == "user-documents")
        #expect(report.verdict(for: bundledImage) == nil)
    }

    @Test("Verdicts cover items, containers and anything inside an item")
    func verdicts() throws {
        let buildFile = file("Index.db", size: 100)
        let derivedData = directory("DerivedData", [directory("App-xyz", [buildFile])])
        let caches = directory("Caches", [directory("com.example.app", [file("blob", size: 10)])])
        let root = home([directory("Library", [directory("Developer", [directory("Xcode", [derivedData])]), caches])])
        let report = try analyze(root)

        #expect(report.verdict(for: derivedData)?.rule.id == "xcode-derived-data")
        let inside = try #require(report.verdict(for: buildFile))
        guard case .inside(let item) = inside.scope else {
            Issue.record("Expected an inside verdict, got \(inside.scope)")
            return
        }
        #expect(item === derivedData)

        let container = try #require(report.verdict(for: caches))
        guard case .container = container.scope else {
            Issue.record("Expected a container verdict, got \(container.scope)")
            return
        }
        #expect(container.rule.id == "user-caches")
        #expect(report.verdict(for: root) == nil)
    }

    @Test("A scan inside a matched folder is covered by that folder's rule")
    func scanRootInsideRule() throws {
        let root = directory("\(Self.homePath)/Library/Developer/Xcode/DerivedData/App-xyz", [file("Index.db", size: 100)])
        root.finalizeTree()
        let report = try analyze(root)

        #expect(report.verdict(for: root)?.rule.id == "xcode-derived-data")
        #expect(findingFor("xcode-derived-data", in: report)?.allocatedSize == 100)
    }

    @Test("A volume root scan matches system folders and home rules by absolute path")
    func volumeRootScan() throws {
        let derivedData = directory("DerivedData", [file("a", size: 100)])
        let root = directory("/", [
            directory("System", [file("kernel", size: 1_000)]),
            directory("Users", [directory("tester", [directory("Library", [directory("Developer", [directory("Xcode", [derivedData])])])])])
        ])
        root.finalizeTree()
        let report = try analyze(root)

        #expect(findingFor("macos-system", in: report)?.allocatedSize == 1_000)
        #expect(findingFor("xcode-derived-data", in: report)?.items.map(\.node) == [derivedData])
    }
}
