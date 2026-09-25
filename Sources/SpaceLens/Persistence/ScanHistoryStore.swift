import Foundation

struct ScanHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id: UUID = UUID()
    var completedAt: Date
    var report: ScanReport

    var rootPath: String { report.rootPath }

    var displayName: String {
        report.rootPath == "/"
            ? (FileManager.default.displayName(atPath: "/"))
            : URL(filePath: report.rootPath).lastPathComponent
    }
}

/// Persists recent scan reports as JSON in Application Support.
struct ScanHistoryStore: Sendable {
    static let maxEntries = 50

    let fileURL: URL

    init(fileURL: URL = AppDirectories.applicationSupport.appending(path: "ScanHistory.json")) {
        self.fileURL = fileURL
    }

    func load() throws -> [ScanHistoryEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([ScanHistoryEntry].self, from: Data(contentsOf: fileURL))
    }

    /// Prepends `entry`, trims to `maxEntries`, persists and returns the new history.
    @discardableResult
    func append(_ entry: ScanHistoryEntry) throws -> [ScanHistoryEntry] {
        let existing = (try? load()) ?? []
        let history = Array(([entry] + existing).prefix(Self.maxEntries))
        try save(history)
        return history
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    private func save(_ history: [ScanHistoryEntry]) throws {
        try AppDirectories.ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AppDirectories.writePrivately(try encoder.encode(history), to: fileURL)
    }
}
