import Foundation

/// Compact binary encoding of a `FileNode` tree.
///
/// Nodes are written in pre-order with LEB128 varints, then the payload is LZ4-compressed. LZ4 is chosen
/// over LZFSE because it compresses ~50x faster; this is a cache, so speed matters more than ratio.
/// Aggregates are not stored; they are recomputed by `finalizeTree()` after decoding.
enum SnapshotCodec {
    enum DecodingError: Error, Equatable {
        case truncated
        case invalidCategory(UInt64)
        case invalidName
        case trailingBytes
    }

    private static let categories = FileCategory.allCases

    static func encode(_ root: FileNode) throws -> Data {
        var writer = ByteWriter()
        writer.reserve(root.fileCount * 48 + root.directoryCount * 16)
        encodeNode(root, into: &writer)
        return try (Data(writer.bytes) as NSData).compressed(using: .lz4) as Data
    }

    static func decode(_ data: Data) throws -> FileNode {
        let payload = try (data as NSData).decompressed(using: .lz4) as Data
        return try payload.withUnsafeBytes { buffer in
            var reader = ByteReader(buffer: buffer)
            let root = try decodeNode(from: &reader)
            guard reader.isAtEnd else { throw DecodingError.trailingBytes }
            root.finalizeTree()
            return root
        }
    }

    private static func encodeNode(_ node: FileNode, into writer: inout ByteWriter) {
        writer.writeVarint(UInt64(node.attributes.rawValue))
        writer.writeVarint(UInt64(categories.firstIndex(of: node.category) ?? 0))
        writer.writeString(node.name)
        writer.writeVarint(node.fileID)
        writer.writeVarint(UInt64(max(0, node.ownSize)))
        writer.writeVarint(UInt64(max(0, node.allocatedSize)))
        writer.writeVarint(node.cloneID)
        writer.writeVarint(zigzag(node.modificationTime))
        if node.isDirectory {
            writer.writeVarint(UInt64(node.children.count))
            for child in node.children {
                encodeNode(child, into: &writer)
            }
        }
    }

    private static func decodeNode(from reader: inout ByteReader) throws -> FileNode {
        let attributes = FileNode.Attributes(rawValue: UInt16(truncatingIfNeeded: try reader.readVarint()))
        let categoryIndex = try reader.readVarint()
        guard categoryIndex < UInt64(categories.count) else { throw DecodingError.invalidCategory(categoryIndex) }
        let node = FileNode(
            name: try reader.readString(),
            fileID: try reader.readVarint(),
            attributes: attributes,
            category: categories[Int(categoryIndex)],
            ownSize: Int64(truncatingIfNeeded: try reader.readVarint()),
            allocatedSize: Int64(truncatingIfNeeded: try reader.readVarint()),
            cloneID: try reader.readVarint(),
            modificationTime: unzigzag(try reader.readVarint())
        )
        if node.isDirectory {
            let childCount = try reader.readVarint()
            // Every node takes at least one byte; reject counts the remaining input cannot satisfy.
            guard childCount <= UInt64(reader.remaining) else { throw DecodingError.truncated }
            var children: [FileNode] = []
            children.reserveCapacity(Int(childCount))
            for _ in 0..<childCount {
                children.append(try decodeNode(from: &reader))
            }
            node.setChildren(children)
        }
        return node
    }

    private static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    private static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }
}

private struct ByteWriter {
    private(set) var bytes: [UInt8] = []

    mutating func reserve(_ capacity: Int) {
        bytes.reserveCapacity(capacity)
    }

    mutating func writeVarint(_ value: UInt64) {
        var remaining = value
        while remaining >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: remaining) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
    }

    mutating func writeString(_ string: String) {
        let utf8 = string.utf8
        writeVarint(UInt64(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

private struct ByteReader {
    private let buffer: UnsafeRawBufferPointer
    private var offset = 0

    init(buffer: UnsafeRawBufferPointer) {
        self.buffer = buffer
    }

    var isAtEnd: Bool { offset == buffer.count }
    var remaining: Int { buffer.count - offset }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < buffer.count, shift < 64 else { throw SnapshotCodec.DecodingError.truncated }
            let byte = buffer[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func readString() throws -> String {
        let length = try readVarint()
        guard length <= UInt64(remaining) else { throw SnapshotCodec.DecodingError.truncated }
        let slice = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + Int(length))])
        offset += Int(length)
        guard let string = String(validating: slice, as: UTF8.self) else {
            throw SnapshotCodec.DecodingError.invalidName
        }
        return string
    }
}
