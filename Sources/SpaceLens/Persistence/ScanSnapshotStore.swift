import CryptoKit
import Foundation

enum AppDirectories {
    static let folderName = "SpaceLens"

    static var caches: URL {
        URL.cachesDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    static var applicationSupport: URL {
        URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Creates `url` readable only by the current user: snapshots and history list private file names.
    static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    static func writePrivately(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// A persisted scan result that later scans can update incrementally.
struct ScanSnapshot: Sendable {
    struct Metadata: Codable, Sendable {
        static let currentFormatVersion = 1

        var formatVersion: Int = Self.currentFormatVersion
        var rootPath: String
        var options: ScanOptions
        /// FSEvents position captured when the scan started; nil when the volume keeps no journal.
        var checkpoint: ChangeJournal.Checkpoint?
        var report: ScanReport
    }

    var metadata: Metadata
    var root: FileNode
}

/// Stores one snapshot per scan root in the caches directory.
///
/// File layout: 4-byte magic, UInt32 metadata length, JSON metadata, `SnapshotCodec` payload. Keeping the
/// metadata uncompressed and in front lets validity checks skip decoding the tree.
struct ScanSnapshotStore: Sendable {
    private static let magic = Data("SLS2".utf8)

    let directory: URL

    init(directory: URL = AppDirectories.caches.appending(path: "Snapshots", directoryHint: .isDirectory)) {
        self.directory = directory
    }

    func save(_ snapshot: ScanSnapshot) throws {
        try AppDirectories.ensurePrivateDirectory(directory)
        let metadata = try JSONEncoder().encode(snapshot.metadata)
        let payload = try SnapshotCodec.encode(snapshot.root)

        var data = Self.magic
        withUnsafeBytes(of: UInt32(metadata.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(metadata)
        data.append(payload)
        try AppDirectories.writePrivately(data, to: fileURL(forRootPath: snapshot.metadata.rootPath))
    }

    /// Loads the snapshot for `rootPath` if one exists in the current format with matching options.
    func load(rootPath: String, options: ScanOptions) throws -> ScanSnapshot? {
        let url = fileURL(forRootPath: rootPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        guard data.count > 8, data.prefix(4) == Self.magic else { return nil }
        let metadataLength = data.subdata(in: 4..<8).withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
        let metadataEnd = 8 + metadataLength
        guard metadataEnd <= data.count else { return nil }

        let metadata = try JSONDecoder().decode(ScanSnapshot.Metadata.self, from: data.subdata(in: 8..<metadataEnd))
        guard metadata.formatVersion == ScanSnapshot.Metadata.currentFormatVersion,
              metadata.rootPath == rootPath,
              metadata.options == options
        else { return nil }

        let root = try SnapshotCodec.decode(data.subdata(in: metadataEnd..<data.count))
        return ScanSnapshot(metadata: metadata, root: root)
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func fileURL(forRootPath rootPath: String) -> URL {
        let digest = SHA256.hash(data: Data(rootPath.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name + ".snapshot", directoryHint: .notDirectory)
    }
}
