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
    public let reason: String?
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
            return total + entry.recommendedItems.reduce(0) { $0 + $1.bytes }
        }
    }

    public func entry(id: String) -> CacheEntry? { entries.first { $0.id == id } }

    public func item(id: String) -> CacheItem? {
        let entryID = id.split(separator: "/", maxSplits: 1).first.map(String.init) ?? id
        return entry(id: entryID)?.items.first { $0.id == id }
    }

    /// Ids selected by `--all-safe`: every non-empty cleanable safe cache, plus recommended items of
    /// regenerable caches. User data is never included.
    public var allSafeIDs: [String] {
        entries.flatMap { entry -> [String] in
            if entry.safety == .safe, entry.isCleanable { return entry.bytes > 0 ? [entry.id] : [] }
            if entry.safety == .regenerable { return entry.recommendedItems.map(\.id) }
            return []
        }
    }
}
