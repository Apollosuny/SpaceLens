import Darwin
import Foundation
@testable import SpaceLens

/// A temporary directory tree for scanner tests, removed on deinit.
final class Fixture {
    /// Canonical (symlink-resolved) root path.
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "SpaceLensTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        root = ScanScope.canonicalPath(base.path)
    }

    deinit {
        // Restore permissions changed by tests so cleanup can descend everywhere.
        if let enumerator = FileManager.default.enumerator(atPath: root) {
            for case let relative as String in enumerator {
                chmod(path(relative), 0o755)
            }
        }
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String {
        relative.isEmpty ? root : root + "/" + relative
    }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    @discardableResult
    func writeFile(_ relative: String, bytes: Int) throws -> String {
        let filePath = path(relative)
        try FileManager.default.createDirectory(
            atPath: (filePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            // Random content so APFS cannot store it compactly.
            arc4random_buf(buffer.baseAddress!, buffer.count)
        }
        try data.write(to: URL(filePath: filePath))
        return filePath
    }

    func symlink(_ relative: String, to destination: String) throws {
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: destination)
    }

    func hardLink(_ relative: String, to existing: String) throws {
        try FileManager.default.linkItem(atPath: path(existing), toPath: path(relative))
    }

    func clone(_ relative: String, from existing: String) throws {
        guard clonefile(path(existing), path(relative), 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Creates a file of `logicalBytes` with a single written byte at the end.
    func writeSparseFile(_ relative: String, logicalBytes: Int) throws {
        let fd = open(path(relative), O_CREAT | O_WRONLY | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        var byte: UInt8 = 1
        guard pwrite(fd, &byte, 1, off_t(logicalBytes - 1)) == 1 else { throw POSIXError(.EIO) }
    }

    func setPermissions(_ relative: String, _ mode: mode_t) {
        chmod(path(relative), mode)
    }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: path(relative))
    }

    /// Sum of allocated bytes of regular files under `relative`, via lstat.
    func allocatedBytes(_ relative: String) -> Int64 {
        var info = stat()
        guard lstat(path(relative), &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }
}

extension Fixture {
    func scan(options: ScanOptions = ScanOptions()) async throws -> (root: FileNode, context: ScanContext) {
        let context = makeContext(options: options)
        let root = try await FileScanner(context: context).scanRoot()
        return (root, context)
    }

    func makeContext(options: ScanOptions = ScanOptions()) -> ScanContext {
        ScanContext(scope: ScanScope(rootPath: root, options: options, firmlinks: []), progress: ScanProgress())
    }
}

extension FileNode {
    /// Descends by path components relative to this node.
    func descendant(_ relative: String) -> FileNode? {
        var node: FileNode? = self
        for component in relative.split(separator: "/") {
            node = node?.child(named: String(component))
        }
        return node
    }

    /// Stable structural description for comparing trees in tests.
    func structure() -> [String: Int64] {
        var result: [String: Int64] = [:]
        func visit(_ node: FileNode, _ prefix: String) {
            let key = prefix.isEmpty ? "." : prefix
            result[key] = node.isDirectory ? node.totalAllocatedSize : node.allocatedSize
            for child in node.children {
                visit(child, prefix.isEmpty ? child.name : prefix + "/" + child.name)
            }
        }
        visit(self, "")
        return result
    }
}
