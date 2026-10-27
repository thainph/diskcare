import Darwin

/// Kind of a directory entry as reported by getattrlistbulk(2).
enum EntryType {
    case file, directory, symlink, other
}

/// One entry decoded from a getattrlistbulk buffer.
/// `name` points into the reader's buffer and is only valid inside the enumeration callback.
struct RawEntry {
    let name: UnsafeBufferPointer<UInt8>
    let type: EntryType
    let allocatedSize: Int64
    let linkCount: UInt32
    let fileID: UInt64
    let modifiedAt: Int64
}

/// Reads directory entries in bulk with getattrlistbulk(2): a single syscall returns
/// hundreds of entries together with their attributes, avoiding one stat() per file.
/// Not thread-safe; each worker owns its own reader (and buffer).
final class BulkDirectoryReader {
    private static let bufferSize = 256 * 1024

    // With FSOPT_PACK_INVAL_ATTRS the common attributes are always packed, in bit order and
    // 4-byte aligned. The file attribute group is only present for non-directories
    // (directory records omit it entirely):
    //   u32 length | attribute_set_t (20) | name attrreference (8) | objtype u32 |
    //   modtime timespec (16) | fileid u64 | [linkcount u32 | allocsize off_t] | name bytes
    private enum Offset {
        static let returnedFileAttributes = 16
        static let name = 24
        static let objectType = 32
        static let modifiedAt = 36
        static let fileID = 52
        static let commonLength = 60
        static let linkCount = 60
        static let allocatedSize = 64
        static let fileLength = 72
    }

    private let fileAttributeMask = attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
        | attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

    private let buffer: UnsafeMutableRawPointer
    private var attributes: attrlist

    init() {
        buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 16)
        attributes = attrlist()
        attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_MODTIME)
            | attrgroup_t(truncatingIfNeeded: ATTR_CMN_FILEID)
        attributes.fileattr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_LINKCOUNT)
            | attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)
    }

    deinit {
        buffer.deallocate()
    }

    /// Enumerates every entry of the directory open at `fd`. Returns 0 on success or an errno.
    func forEachEntry(of fd: Int32, _ body: (RawEntry) -> Void) -> Int32 {
        let options = UInt64(FSOPT_PACK_INVAL_ATTRS)
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, Self.bufferSize, options)
            if count == 0 { return 0 }
            if count < 0 { return errno }

            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                if length >= Offset.commonLength {
                    body(decode(record, length: length))
                }
                record += length
            }
        }
    }

    private func decode(_ record: UnsafeRawPointer, length: Int) -> RawEntry {
        let nameRef = record + Offset.name
        let nameOffset = Int(nameRef.loadUnaligned(as: Int32.self))
        let nameLength = Int(nameRef.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        let nameStart = (nameRef + nameOffset).assumingMemoryBound(to: UInt8.self)
        // attr length includes the trailing NUL.
        let name = UnsafeBufferPointer(start: nameStart, count: max(nameLength - 1, 0))

        let type: EntryType
        switch record.loadUnaligned(fromByteOffset: Offset.objectType, as: UInt32.self) {
        case 1: type = .file       // VREG
        case 2: type = .directory  // VDIR
        case 5: type = .symlink    // VLNK
        default: type = .other
        }

        let returnedFile = record.loadUnaligned(fromByteOffset: Offset.returnedFileAttributes, as: attrgroup_t.self)
        let hasFileAttributes = type != .directory && length >= Offset.fileLength
            && returnedFile & fileAttributeMask == fileAttributeMask

        return RawEntry(
            name: name,
            type: type,
            allocatedSize: hasFileAttributes ? record.loadUnaligned(fromByteOffset: Offset.allocatedSize, as: Int64.self) : 0,
            linkCount: hasFileAttributes ? record.loadUnaligned(fromByteOffset: Offset.linkCount, as: UInt32.self) : 1,
            fileID: record.loadUnaligned(fromByteOffset: Offset.fileID, as: UInt64.self),
            modifiedAt: Int64(record.loadUnaligned(fromByteOffset: Offset.modifiedAt, as: Int.self))
        )
    }
}
