import Foundation
import Testing
@testable import SpaceLens

@Suite("ChangeJournal")
struct ChangeJournalTests {
    @Test("Replays directory changes made after a checkpoint")
    func replaysChanges() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("watched")
        try fixture.makeDirectory("untouched")
        let checkpoint = try #require(ChangeJournal.checkpoint(forPath: fixture.root), "temp volume keeps an FSEvents journal")

        try fixture.writeFile("watched/new-file", bytes: 100)

        // fseventsd publishes with a small delay; poll until the change is visible.
        var changes = ChangeSet()
        for _ in 0..<50 where !changes.directories.contains(fixture.path("watched")) {
            try await Task.sleep(for: .milliseconds(200))
            changes = try #require(await ChangeJournal.changes(since: checkpoint, under: fixture.root, firmlinks: []))
        }

        #expect(changes.directories.contains(fixture.path("watched")))
        #expect(!changes.directories.contains(fixture.path("untouched")))
        #expect(changes.directories.allSatisfy { $0.hasPrefix(fixture.root) })
    }

    @Test("A checkpoint from a different journal is rejected")
    func rejectsForeignJournal() async throws {
        let fixture = try Fixture()
        let checkpoint = ChangeJournal.Checkpoint(eventID: 1, journalUUID: "00000000-0000-0000-0000-000000000000")
        #expect(await ChangeJournal.changes(since: checkpoint, under: fixture.root, firmlinks: []) == nil)
    }
}
