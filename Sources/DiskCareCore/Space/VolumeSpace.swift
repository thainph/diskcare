import Darwin
import Foundation

/// Capacity of the volume holding a path, measured from resource values only (no scanning).
public struct VolumeSpace: Sendable, Codable, Equatable {
    public let totalBytes: Int64
    /// Free space as `df` reports it (`volumeAvailableCapacityKey`). Alerts use this.
    public let availableBytes: Int64
    /// Free space for important usage: available plus purgeable space macOS frees on demand.
    public let importantAvailableBytes: Int64?
    /// Space used by this volume alone (`ATTR_VOL_SPACEUSED`), not the whole APFS container.
    public let volumeUsedBytes: Int64?

    public init(totalBytes: Int64, availableBytes: Int64, importantAvailableBytes: Int64? = nil, volumeUsedBytes: Int64? = nil) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.importantAvailableBytes = importantAvailableBytes
        self.volumeUsedBytes = volumeUsedBytes
    }

    /// Space macOS can reclaim on demand (snapshots, iCloud copies…), not counted as free by `df`.
    public var purgeableBytes: Int64 {
        max(0, (importantAvailableBytes ?? availableBytes) - availableBytes)
    }

    public static func measure(at path: String) -> VolumeSpace? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity, let available = values?.volumeAvailableCapacity else { return nil }
        return VolumeSpace(
            totalBytes: Int64(total), availableBytes: Int64(available),
            importantAvailableBytes: values?.volumeAvailableCapacityForImportantUsage,
            volumeUsedBytes: volumeUsedBytes(at: path)
        )
    }

    /// Free space as `df` reports it on the volume containing `path`.
    public static func available(at path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    /// Free space for important usage (includes purgeable space) on the volume containing `path`.
    public static func importantAvailable(at path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// `getattrlist(ATTR_VOL_SPACEUSED)` on the mount point of the volume containing `path`.
    static func volumeUsedBytes(at path: String) -> Int64? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        let mountPoint = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        // Reply: u_int32_t length, then off_t packed at 4-byte alignment.
        var buffer = [UInt8](repeating: 0, count: 64)
        let status = buffer.withUnsafeMutableBytes { getattrlist(mountPoint, &request, $0.baseAddress, $0.count, 0) }
        guard status == 0 else { return nil }
        let used = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
        return used > 0 ? used : nil
    }
}
