import Darwin

/// Metadata for a single directory entry, as reported by `getattrlistbulk(2)`.
struct DirectoryEntry: Sendable {
    enum Kind: Sendable {
        case directory
        case regularFile
        case symlink
        case other
    }

    let name: String
    let kind: Kind
    let fileID: UInt64
    /// BSD flags (`st_flags`), e.g. `UF_HIDDEN`, `UF_COMPRESSED`.
    let bsdFlags: UInt32
    let modificationTime: Int64
    /// True for mount points and automount triggers; scanning never descends into these implicitly.
    let isMountBoundary: Bool
    let linkCount: UInt32
    /// Logical size of all forks.
    let logicalSize: Int64
    /// Allocated size of all forks.
    let allocatedSize: Int64
    /// Bytes that would be freed immediately if the file were deleted (APFS only).
    let privateSize: Int64?
    /// Identifies the data stream; pure clones share it (APFS only).
    let cloneID: UInt64?
    /// `EF_*` flags from `<sys/stat.h>`.
    let extendedFlags: UInt64

    var isHidden: Bool {
        name.hasPrefix(".") || bsdFlags & UInt32(UF_HIDDEN) != 0
    }

    var mayShareBlocks: Bool {
        extendedFlags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
    }

    /// A pure APFS clone: every block is shared with the other members of its clone family.
    var sharesAllBlocks: Bool {
        extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS) != 0
    }

    var isSparse: Bool {
        extendedFlags & UInt64(EF_IS_SPARSE) != 0
    }

    var isPurgeable: Bool {
        extendedFlags & UInt64(EF_IS_PURGEABLE) != 0
    }

    var isCompressed: Bool {
        bsdFlags & UInt32(UF_COMPRESSED) != 0
    }
}

struct DirectoryReadError: Error, Sendable, Equatable {
    let path: String
    let code: Int32

    var isPermissionDenied: Bool { code == EACCES || code == EPERM }
    var isNotFound: Bool { code == ENOENT || code == ENOTDIR }
}

/// Reads a directory's entries and their attributes in bulk.
///
/// `getattrlistbulk` returns metadata for many entries per syscall, which is substantially faster than
/// `readdir` + `lstat` per entry and exposes APFS-specific attributes (clone IDs, private size, sparse
/// flags). Filesystems without native support are emulated by the kernel, so no fallback is needed.
/// Symlinks are never followed.
enum DirectoryReader {
    /// Per-entry error callback: (entry name, errno).
    typealias EntryErrorHandler = (String, Int32) -> Void

    private static let bufferSize = 64 * 1024

    static func readEntries(
        atPath path: String,
        onEntryError: EntryErrorHandler = { _, _ in }
    ) throws(DirectoryReadError) -> [DirectoryEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryReadError(path: path, code: errno) }
        defer { close(fd) }

        var attributeList = makeAttributeList()
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [DirectoryEntry] = []
        while true {
            let count = getattrlistbulk(fd, &attributeList, buffer, bufferSize, UInt64(FSOPT_ATTR_CMN_EXTENDED))
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryReadError(path: path, code: errno)
            }
            if count == 0 { break }

            var cursor = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(cursor.loadUnaligned(as: UInt32.self))
                switch parseEntry(at: cursor) {
                case .entry(let entry): entries.append(entry)
                case .failed(let name, let code): onEntryError(name, code)
                case .malformed: break
                }
                cursor += length
            }
        }
        return entries
    }

    private static func makeAttributeList() -> attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_ERROR) | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)
        list.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        list.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_TOTALSIZE)
            | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // With FSOPT_ATTR_CMN_EXTENDED the fork group carries the extended common attributes.
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID)
            | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        return list
    }

    private enum ParseResult {
        case entry(DirectoryEntry)
        case failed(name: String, code: Int32)
        case malformed
    }

    /// Parses one packed entry. Attributes appear in the order documented in getattrlist(2), each
    /// 4-byte aligned, and only when their bit is set in the returned attribute set.
    private static func parseEntry(at start: UnsafeRawPointer) -> ParseResult {
        var field = start + MemoryLayout<UInt32>.size
        let returned = field.loadUnaligned(as: attribute_set_t.self)
        field += MemoryLayout<attribute_set_t>.size

        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bit) != 0 }
        func read<T>(_ type: T.Type) -> T {
            let value = field.loadUnaligned(as: T.self)
            field += MemoryLayout<T>.size
            return value
        }

        var errorCode: UInt32 = 0
        if has(returned.commonattr, ATTR_CMN_ERROR) {
            errorCode = read(UInt32.self)
        }

        guard has(returned.commonattr, ATTR_CMN_NAME) else { return .malformed }
        let nameReference = field.loadUnaligned(as: attrreference_t.self)
        let namePointer = field + Int(nameReference.attr_dataoffset)
        // attr_length includes the trailing NUL.
        let nameLength = max(0, Int(nameReference.attr_length) - 1)
        let name = String(decoding: UnsafeRawBufferPointer(start: namePointer, count: nameLength), as: UTF8.self)
        field += MemoryLayout<attrreference_t>.size

        if errorCode != 0 {
            return .failed(name: name, code: Int32(bitPattern: errorCode))
        }

        var objectType = fsobj_type_t(VNON.rawValue)
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) { objectType = read(fsobj_type_t.self) }

        var modificationTime: Int64 = 0
        if has(returned.commonattr, ATTR_CMN_MODTIME) {
            modificationTime = Int64(read(timespec.self).tv_sec)
        }

        var bsdFlags: UInt32 = 0
        if has(returned.commonattr, ATTR_CMN_FLAGS) { bsdFlags = read(UInt32.self) }

        var fileID: UInt64 = 0
        if has(returned.commonattr, ATTR_CMN_FILEID) { fileID = read(UInt64.self) }

        var isMountBoundary = false
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) {
            let status = read(UInt32.self)
            isMountBoundary = status & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0
        }

        var linkCount: UInt32 = 1
        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { linkCount = read(UInt32.self) }
        if has(returned.fileattr, ATTR_FILE_TOTALSIZE) { logicalSize = Int64(read(off_t.self)) }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { allocatedSize = Int64(read(off_t.self)) }

        var privateSize: Int64?
        var cloneID: UInt64?
        var extendedFlags: UInt64 = 0
        if has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) { privateSize = Int64(read(off_t.self)) }
        if has(returned.forkattr, ATTR_CMNEXT_CLONEID) { cloneID = read(UInt64.self) }
        if has(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS) { extendedFlags = read(UInt64.self) }

        let kind: DirectoryEntry.Kind = switch objectType {
        case fsobj_type_t(VDIR.rawValue): .directory
        case fsobj_type_t(VREG.rawValue): .regularFile
        case fsobj_type_t(VLNK.rawValue): .symlink
        default: .other
        }

        return .entry(DirectoryEntry(
            name: name,
            kind: kind,
            fileID: fileID,
            bsdFlags: bsdFlags,
            modificationTime: modificationTime,
            isMountBoundary: isMountBoundary,
            linkCount: linkCount,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            privateSize: privateSize,
            cloneID: cloneID,
            extendedFlags: extendedFlags
        ))
    }
}
