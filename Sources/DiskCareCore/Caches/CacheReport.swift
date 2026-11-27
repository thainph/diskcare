import Foundation

public enum CacheCleanMethod: String, Sendable, Codable {
    /// Run the tool's own cleanup command.
    case native
    /// Delete the contents of each cache directory (the directory itself stays).
    case deleteContents
    /// Not cleanable by DiskCare (user data, or no command available).
    case reportOnly
}

/// A separately cleanable part of a cache: one browser revision, one DerivedData project…
public struct CacheItem: Sendable, Codable, Identifiable {
    /// `<entry id>/<directory name>`, e.g. `playwright/chromium-1228`.
    public let id: String
    public let entryID: String
    public let name: String
    public let path: String
    public let bytes: Int64
    public let hardlinkedBytes: Int64
    public let lastUsedAt: Date?
    /// Old version or stale project: suggested for cleanup.
    public let isRecommended: Bool
    /// Ticked by "Select all safe" / `--all-safe`. Only pure caches qualify, never items that may hold
    /// output the user cannot rebuild; recommended alone is not enough.
    public let isPreselectable: Bool
    public let reason: String?

    public init(
        id: String, entryID: String, name: String, path: String, bytes: Int64, hardlinkedBytes: Int64,
        lastUsedAt: Date?, isRecommended: Bool, isPreselectable: Bool = false, reason: String?
    ) {
        self.id = id
        self.entryID = entryID
        self.name = name
        self.path = path
        self.bytes = bytes
        self.hardlinkedBytes = hardlinkedBytes
        self.lastUsedAt = lastUsedAt
        self.isRecommended = isRecommended
        self.isPreselectable = isPreselectable && isRecommended
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case id, entryID, name, path, bytes, hardlinkedBytes, lastUsedAt, isRecommended, isPreselectable, reason
    }

    /// Reports saved by older versions have no `isPreselectable`: treat it as false.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            entryID: try container.decode(String.self, forKey: .entryID),
            name: try container.decode(String.self, forKey: .name),
            path: try container.decode(String.self, forKey: .path),
            bytes: try container.decode(Int64.self, forKey: .bytes),
            hardlinkedBytes: try container.decode(Int64.self, forKey: .hardlinkedBytes),
            lastUsedAt: try container.decodeIfPresent(Date.self, forKey: .lastUsedAt),
            isRecommended: try container.decode(Bool.self, forKey: .isRecommended),
            isPreselectable: try container.decodeIfPresent(Bool.self, forKey: .isPreselectable) ?? false,
            reason: try container.decodeIfPresent(String.self, forKey: .reason)
        )
    }

    /// Whether this item lies inside `other` (a different, enclosing item).
    func isNested(in other: CacheItem) -> Bool {
        path.hasPrefix(other.path + "/")
    }
}

extension Array where Element == CacheItem {
    /// Drops items that lie inside another item of the list, so nested selections are counted once.
    func outermost() -> [CacheItem] {
        filter { item in !contains { $0.id != item.id && item.isNested(in: $0) } }
    }
}

public struct CacheEntry: Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let category: CacheCategory
    public let safety: CacheSafety
    /// Existing directories that were measured.
    public let paths: [String]
    public let bytes: Int64
    public let hardlinkedBytes: Int64
    public let files: Int64
    /// Latest file modification inside the cache (a proxy for last use).
    public let lastModifiedAt: Date?
    public let method: CacheCleanMethod
    /// Display form of the native command, when `method == .native`.
    public let command: String?
    public let nativeCommand: NativeCleanCommand?
    public let fallback: CacheFallback
    public let note: String?
    /// Sorted by size, largest first.
    public let items: [CacheItem]

    public var isCleanable: Bool { safety.isCleanable && method != .reportOnly }
    public var recommendedItems: [CacheItem] { safety.isCleanable ? items.filter(\.isRecommended) : [] }

    public func idleDays(now: Date = Date()) -> Int? {
        lastModifiedAt.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}

public struct CacheReport: Sendable, Codable {
    public let scannedAt: Date
    public let durationSeconds: Double
    /// Existing caches only, largest first.
    public let entries: [CacheEntry]

    public var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    /// Bytes in safe caches plus recommended items (old versions, stale projects) of regenerable ones.
    public var safeReclaimableBytes: Int64 {
        entries.reduce(0) { total, entry in
            if entry.safety == .safe, entry.isCleanable { return total + entry.bytes }
            return total + entry.recommendedItems.outermost().reduce(0) { $0 + $1.bytes }
        }
    }

    public func entry(id: String) -> CacheEntry? { entries.first { $0.id == id } }

    public func item(id: String) -> CacheItem? {
        let entryID = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
        return entry(id: entryID)?.items.first { $0.id == id }
    }

    /// Ids selected by `--all-safe`: every non-empty cleanable safe cache, plus preselectable items of
    /// regenerable caches. User data is never included.
    public var allSafeIDs: [String] {
        entries.flatMap { entry -> [String] in
            if entry.safety == .safe, entry.isCleanable { return entry.bytes > 0 ? [entry.id] : [] }
            if entry.safety == .regenerable { return entry.recommendedItems.filter(\.isPreselectable).outermost().map(\.id) }
            return []
        }
    }
}
