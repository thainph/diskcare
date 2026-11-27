import Foundation

/// When a size change between two scans is worth reporting.
public struct GrowthThresholds: Sendable, Codable, Equatable {
    /// Always report growth of at least this much.
    public var absoluteBytes: Int64
    /// Report smaller growth when it is at least `relativeMinimumBytes` and `relativeFraction` of the old size.
    public var relativeMinimumBytes: Int64
    public var relativeFraction: Double
    /// Report an artifact absent from the baseline once it reaches this size.
    public var newArtifactBytes: Int64

    public init(
        absoluteBytes: Int64 = 5_000_000_000,
        relativeMinimumBytes: Int64 = 2_000_000_000,
        relativeFraction: Double = 1.0,
        newArtifactBytes: Int64 = 2_000_000_000
    ) {
        self.absoluteBytes = absoluteBytes
        self.relativeMinimumBytes = relativeMinimumBytes
        self.relativeFraction = relativeFraction
        self.newArtifactBytes = newArtifactBytes
    }

    public func isSignificant(_ entry: GrowthEntry) -> Bool {
        if entry.isNew { return entry.bytesNow >= newArtifactBytes }
        if entry.delta >= absoluteBytes { return true }
        guard entry.delta >= relativeMinimumBytes, let ratio = entry.ratio else { return false }
        return ratio >= relativeFraction
    }
}

public struct GrowthReport: Sendable, Codable {
    public let days: Int
    public let latest: ScanRecord?
    public let baseline: ScanRecord?
    /// Entries passing the thresholds, largest growth first.
    public let alerts: [GrowthEntry]
    /// All growth above `minimumBytes`, largest first (includes alerts).
    public let top: [GrowthEntry]
    /// Free space with each scan in the period, oldest first.
    public let freeSpace: [FreeSpacePoint]
    /// Trend of the periodic free-space samples; nil until there is enough history.
    public var forecast: SpaceForecast?

    /// Free-space change over the period (negative means the disk filled up).
    public var freeSpaceChange: Int64? {
        guard let first = freeSpace.first, let last = freeSpace.last, freeSpace.count > 1 else { return nil }
        return last.freeBytes - first.freeBytes
    }
}

/// Compares the latest scan with the scan closest to N days ago.
public enum GrowthAnalyzer {
    public static func analyze(
        _ store: HistoryStore,
        days: Int = 7,
        thresholds: GrowthThresholds = GrowthThresholds(),
        minimumBytes: Int64 = 100_000_000,
        now: Date = Date()
    ) throws -> GrowthReport {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let freeSpace = try store.freeSpaceSeries(since: since)
        let forecast = SpaceForecast.make(samples: try store.freeSamples(since: now.addingTimeInterval(-14 * 86_400)), now: now)
        guard let latest = try store.latestScan(), let baseline = try store.baselineScan(for: since, before: latest) else {
            return GrowthReport(days: days, latest: try store.latestScan(), baseline: nil, alerts: [], top: [], freeSpace: freeSpace, forecast: forecast)
        }
        let entries = try store.growth(from: baseline, to: latest, minimumBytes: 1)
        return GrowthReport(
            days: days, latest: latest, baseline: baseline,
            alerts: significant(entries, thresholds: thresholds),
            top: entries.filter { $0.delta >= minimumBytes },
            freeSpace: freeSpace, forecast: forecast
        )
    }

    public static func significant(_ entries: [GrowthEntry], thresholds: GrowthThresholds) -> [GrowthEntry] {
        entries.filter(thresholds.isSignificant).sorted { $0.delta > $1.delta }
    }
}

/// Something that grew between two points in history: an artifact directory or a cache entry.
public struct GrowthSource: Sendable, Codable, Identifiable, Equatable {
    public enum Origin: String, Sendable, Codable {
        case artifact, cache
    }

    public var id: String { "\(origin.rawValue):\(name)" }
    public let origin: Origin
    /// Artifact path, or cache entry id (`homebrew`).
    public let name: String
    public let kind: ArtifactKind?
    public let bytesThen: Int64
    public let bytesNow: Int64
    public let since: Date
    public let until: Date

    public var delta: Int64 { bytesNow - bytesThen }

    public init(origin: Origin, name: String, kind: ArtifactKind?, bytesThen: Int64, bytesNow: Int64, since: Date, until: Date) {
        self.origin = origin
        self.name = name
        self.kind = kind
        self.bytesThen = bytesThen
        self.bytesNow = bytesNow
        self.since = since
        self.until = until
    }

    public init(_ entry: GrowthEntry) {
        self.init(origin: .artifact, name: entry.path, kind: entry.kind, bytesThen: entry.bytesThen, bytesNow: entry.bytesNow, since: entry.since, until: entry.until)
    }
}

extension GrowthAnalyzer {
    /// Fastest-growing artifacts and cache entries over the last `days`, largest growth first.
    public static func fastestGrowing(
        _ store: HistoryStore, days: Int = 7, limit: Int = 3, minimumBytes: Int64 = 100_000_000, now: Date = Date()
    ) throws -> [GrowthSource] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        let artifacts = try store.growth(since: since, minimumBytes: minimumBytes).map(GrowthSource.init)
        let caches = try store.cacheGrowth(since: since, minimumBytes: minimumBytes)
        return (artifacts + caches)
            .sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.name < $1.name }
            .prefix(limit).map { $0 }
    }
}
