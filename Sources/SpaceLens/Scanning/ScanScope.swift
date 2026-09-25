import Foundation

/// Decides which directories a scan may enter.
///
/// Rules:
/// - Symlinks are never followed, so symlink loops cannot occur.
/// - Mount points and automount triggers below the root are not entered (like `du -x`), which keeps
///   scans on one volume and avoids network mounts.
/// - Exception for the boot volume group: when scanning `/`, the Data volume mounted at
///   `/System/Volumes/Data` is entered, but its firmlinked directories are skipped because they are
///   already reached through their firmlinks (`/Users`, `/Applications`, ...). This counts every
///   byte of the Data volume exactly once.
struct ScanScope: Sendable {
    static let dataVolumeMountPoint = "/System/Volumes/Data"

    let rootPath: String
    let options: ScanOptions
    private let allowedMountPoints: Set<String>
    private let excludedPaths: Set<String>

    init(rootPath: String, options: ScanOptions, firmlinks: [Firmlink] = Firmlink.systemFirmlinks()) {
        self.rootPath = rootPath
        self.options = options
        if rootPath == "/" {
            allowedMountPoints = [Self.dataVolumeMountPoint]
            excludedPaths = Set(firmlinks.map { Self.dataVolumeMountPoint + "/" + $0.dataVolumeRelativePath })
        } else {
            allowedMountPoints = []
            excludedPaths = []
        }
    }

    func includes(_ entry: DirectoryEntry) -> Bool {
        options.includeHiddenFiles || !entry.isHidden
    }

    func shouldDescend(into entry: DirectoryEntry, atPath path: String) -> Bool {
        if entry.isMountBoundary && !allowedMountPoints.contains(path) { return false }
        return !excludedPaths.contains(path)
    }

    static func childPath(_ parent: String, _ name: String) -> String {
        parent.hasSuffix("/") ? parent + name : parent + "/" + name
    }

    /// Canonical absolute path with symlinks resolved, so cache keys and FSEvents paths line up.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Used space of the volume when `path` is a volume root; drives the determinate progress bar.
    static func estimatedUsedBytes(forVolumeRoot path: String) -> Int64? {
        let url = URL(filePath: path, directoryHint: .isDirectory)
        guard let values = try? url.resourceValues(forKeys: [
            .isVolumeKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        ]), values.isVolume == true,
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacity
        else { return nil }
        return Int64(max(0, total - available))
    }
}

/// An APFS firmlink from the read-only system volume into the Data volume.
struct Firmlink: Hashable, Sendable {
    /// Path as seen from `/`, e.g. `/Users`.
    let path: String
    /// Path relative to the Data volume root, e.g. `Users`.
    let dataVolumeRelativePath: String

    static func systemFirmlinks(listPath: String = "/usr/share/firmlinks") -> [Firmlink] {
        guard let contents = try? String(contentsOfFile: listPath, encoding: .utf8) else { return [] }
        return parse(contents)
    }

    /// Parses `/usr/share/firmlinks`: one `<absolute path>\t<data-volume-relative path>` per line.
    static func parse(_ contents: String) -> [Firmlink] {
        contents.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: true)
            guard fields.count == 2, fields[0].hasPrefix("/") else { return nil }
            return Firmlink(path: String(fields[0]), dataVolumeRelativePath: String(fields[1]))
        }
    }
}
