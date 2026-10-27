import Foundation

/// One recorded scan (summary row).
public struct ScanRecord: Sendable, Codable, Identifiable, Equatable {
    public let id: Int64
    public let scannedAt: Date
    public let roots: [String]
    public let scannedBytes: Int64
    public let regenerableBytes: Int64
    public let artifactCount: Int
    public let freeBytes: Int64?
    public let dockerBytes: Int64?

    /// Whether `path` lies inside one of the scanned roots.
    public func covers(_ path: String) -> Bool {
        roots.contains { root in
            root == "/" || path == root || path.hasPrefix(root + "/")
        }
    }
}

public struct FreeSpacePoint: Sendable, Codable, Equatable {
    public let date: Date
    public let freeBytes: Int64
}

/// Size change of one artifact (or workspace) between two scans.
public struct GrowthEntry: Sendable, Codable, Identifiable, Equatable {
    public var id: String { path }
    public let path: String
    /// Nil for a workspace (whole repository/worktree total).
    public let kind: ArtifactKind?
    public let bytesThen: Int64
    public let bytesNow: Int64
    /// Absent from the baseline scan although its location was scanned.
    public let isNew: Bool
    public let since: Date
    public let until: Date

    public var delta: Int64 { bytesNow - bytesThen }
    /// Growth relative to the baseline; nil for new entries.
    public var ratio: Double? { bytesThen > 0 ? Double(delta) / Double(bytesThen) : nil }

    public init(path: String, kind: ArtifactKind?, bytesThen: Int64, bytesNow: Int64, isNew: Bool, since: Date, until: Date) {
        self.path = path
        self.kind = kind
        self.bytesThen = bytesThen
        self.bytesNow = bytesNow
        self.isNew = isNew
        self.since = since
        self.until = until
    }
}

/// Scan history in SQLite (WAL). Safe to share across threads; calls are serialized.
public final class HistoryStore: @unchecked Sendable {
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("DiskCare/history.sqlite").path
    }

    /// Artifacts/workspaces smaller than this are not stored (keeps the DB small: a home scan
    /// can find thousands of tiny `__pycache__` dirs). Growth from below this counts as "new".
    public let minimumStoredBytes: Int64
    public let path: String

    private let database: SQLiteDatabase
    private let lock = NSLock()
    private static let schemaVersion: Int64 = 1

    public init(path: String = HistoryStore.defaultPath, minimumStoredBytes: Int64 = 1_000_000) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        self.path = path
        self.minimumStoredBytes = minimumStoredBytes
        database = try SQLiteDatabase(path: path)
        try migrate()
    }

    private func migrate() throws {
        try database.execute("PRAGMA journal_mode = WAL")
        try database.execute("PRAGMA synchronous = NORMAL")
        try database.execute("PRAGMA foreign_keys = ON")
        let version = try database.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        guard version < Self.schemaVersion else { return }
        try database.transaction {
            try database.execute("""
            CREATE TABLE IF NOT EXISTS scans (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                time REAL NOT NULL,
                roots TEXT NOT NULL,
                scanned_bytes INTEGER NOT NULL,
                regenerable_bytes INTEGER NOT NULL,
                artifact_count INTEGER NOT NULL,
                free_bytes INTEGER,
                docker_bytes INTEGER
            );
            CREATE INDEX IF NOT EXISTS scans_time ON scans(time);
            CREATE TABLE IF NOT EXISTS artifact_sizes (
                scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                kind TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                PRIMARY KEY (scan_id, path)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS workspace_sizes (
                scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                path TEXT NOT NULL,
                bytes INTEGER NOT NULL,
                artifact_bytes INTEGER NOT NULL,
                PRIMARY KEY (scan_id, path)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS watch_state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            PRAGMA user_version = \(Self.schemaVersion);
            """)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: Recording

    /// Stores a scan summary plus per-artifact and per-workspace sizes; prunes old history.
    @discardableResult
    public func record(report: ScanReport, freeBytes: Int64?, dockerBytes: Int64? = nil) throws -> ScanRecord {
        let rootsJSON = String(decoding: try JSONEncoder().encode(report.roots), as: UTF8.self)
        let record = try locked {
            try database.transaction { () throws -> ScanRecord in
                try database.run(
                    "INSERT INTO scans (time, roots, scanned_bytes, regenerable_bytes, artifact_count, free_bytes, docker_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)",
                    [
                        .double(report.scannedAt.timeIntervalSince1970), .text(rootsJSON),
                        .int(report.stats.bytes), .int(report.regenerableBytes), .int(Int64(report.artifacts.count)),
                        freeBytes.map(SQLValue.int) ?? .null, dockerBytes.map(SQLValue.int) ?? .null,
                    ]
                )
                let id = database.lastInsertRowID
                try database.run(
                    "INSERT OR REPLACE INTO artifact_sizes (scan_id, path, kind, bytes) VALUES (?, ?, ?, ?)",
                    report.artifacts.filter { $0.totals.bytes >= minimumStoredBytes }.map {
                        [.int(id), .text($0.path), .text($0.kind.rawValue), .int($0.totals.bytes)]
                    }
                )
                try database.run(
                    "INSERT OR REPLACE INTO workspace_sizes (scan_id, path, bytes, artifact_bytes) VALUES (?, ?, ?, ?)",
                    report.workspaces.filter { $0.totals.bytes >= minimumStoredBytes }.map {
                        [.int(id), .text($0.path), .int($0.totals.bytes), .int($0.artifactBytes)]
                    }
                )
                return ScanRecord(
                    id: id, scannedAt: Date(timeIntervalSince1970: report.scannedAt.timeIntervalSince1970),
                    roots: report.roots, scannedBytes: report.stats.bytes, regenerableBytes: report.regenerableBytes,
                    artifactCount: report.artifacts.count, freeBytes: freeBytes, dockerBytes: dockerBytes
                )
            }
        }
        try prune()
        return record
    }

    // MARK: Queries

    private static let scanColumns = "id, time, roots, scanned_bytes, regenerable_bytes, artifact_count, free_bytes, docker_bytes"

    private static func scanRecord(_ row: SQLiteDatabase.Row) -> ScanRecord {
        let roots = (try? JSONDecoder().decode([String].self, from: Data(row.text(2).utf8))) ?? []
        return ScanRecord(
            id: row.int(0), scannedAt: Date(timeIntervalSince1970: row.double(1)), roots: roots,
            scannedBytes: row.int(3), regenerableBytes: row.int(4), artifactCount: Int(row.int(5)),
            freeBytes: row.optionalInt(6), dockerBytes: row.optionalInt(7)
        )
    }

    /// Scans recorded at or after `since`, oldest first.
    public func scans(since: Date = .distantPast) throws -> [ScanRecord] {
        try locked {
            try database.query(
                "SELECT \(Self.scanColumns) FROM scans WHERE time >= ? ORDER BY time, id",
                [.double(since.timeIntervalSince1970)], map: Self.scanRecord
            )
        }
    }

    public func latestScan() throws -> ScanRecord? {
        try locked {
            try database.query("SELECT \(Self.scanColumns) FROM scans ORDER BY time DESC, id DESC LIMIT 1", map: Self.scanRecord).first
        }
    }

    /// Baseline for comparing against `latest`: the last scan at or before `date`, otherwise
    /// the oldest scan after it. Only scans older than `latest` that cover its roots qualify.
    public func baselineScan(for date: Date, before latest: ScanRecord) throws -> ScanRecord? {
        let candidates = try locked {
            try database.query(
                "SELECT \(Self.scanColumns) FROM scans WHERE time < ? ORDER BY time, id",
                [.double(latest.scannedAt.timeIntervalSince1970)], map: Self.scanRecord
            )
        }.filter { candidate in latest.roots.contains { candidate.covers($0) } }
        return candidates.last { $0.scannedAt <= date } ?? candidates.first
    }

    public func artifactSizes(scanID: Int64) throws -> [String: (kind: ArtifactKind, bytes: Int64)] {
        let rows = try locked {
            try database.query("SELECT path, kind, bytes FROM artifact_sizes WHERE scan_id = ?", [.int(scanID)]) { row in
                (row.text(0), ArtifactKind(rawValue: row.text(1)), row.int(2))
            }
        }
        var sizes: [String: (kind: ArtifactKind, bytes: Int64)] = [:]
        for (path, kind, bytes) in rows {
            if let kind { sizes[path] = (kind, bytes) }
        }
        return sizes
    }

    public func workspaceSizes(scanID: Int64) throws -> [String: Int64] {
        let rows = try locked {
            try database.query("SELECT path, bytes FROM workspace_sizes WHERE scan_id = ?", [.int(scanID)]) { ($0.text(0), $0.int(1)) }
        }
        return Dictionary(rows, uniquingKeysWith: { $1 })
    }

    /// Entries that grew by at least `minimumBytes` between the baseline scan for `since`
    /// and the latest scan, largest growth first.
    public func growth(since: Date, minimumBytes: Int64 = 1, includeWorkspaces: Bool = false) throws -> [GrowthEntry] {
        guard let latest = try latestScan(), let baseline = try baselineScan(for: since, before: latest) else { return [] }
        return try growth(from: baseline, to: latest, minimumBytes: minimumBytes, includeWorkspaces: includeWorkspaces)
    }

    public func growth(from baseline: ScanRecord, to latest: ScanRecord, minimumBytes: Int64 = 1, includeWorkspaces: Bool = false) throws -> [GrowthEntry] {
        let then = try artifactSizes(scanID: baseline.id)
        var entries: [GrowthEntry] = []
        for (path, now) in try artifactSizes(scanID: latest.id) {
            let previous = then[path]
            guard previous != nil || baseline.covers(path) else { continue }
            let entry = GrowthEntry(
                path: path, kind: now.kind, bytesThen: previous?.bytes ?? 0, bytesNow: now.bytes,
                isNew: previous == nil, since: baseline.scannedAt, until: latest.scannedAt
            )
            if entry.delta >= minimumBytes { entries.append(entry) }
        }
        if includeWorkspaces {
            let thenWorkspaces = try workspaceSizes(scanID: baseline.id)
            for (path, bytes) in try workspaceSizes(scanID: latest.id) {
                let previous = thenWorkspaces[path]
                guard previous != nil || baseline.covers(path) else { continue }
                let entry = GrowthEntry(
                    path: path, kind: nil, bytesThen: previous ?? 0, bytesNow: bytes,
                    isNew: previous == nil, since: baseline.scannedAt, until: latest.scannedAt
                )
                if entry.delta >= minimumBytes { entries.append(entry) }
            }
        }
        return entries.sorted { $0.delta != $1.delta ? $0.delta > $1.delta : $0.path < $1.path }
    }

    /// Free space recorded with each scan since `since`, oldest first.
    public func freeSpaceSeries(since: Date) throws -> [FreeSpacePoint] {
        try locked {
            try database.query(
                "SELECT time, free_bytes FROM scans WHERE time >= ? AND free_bytes IS NOT NULL ORDER BY time, id",
                [.double(since.timeIntervalSince1970)]
            ) { FreeSpacePoint(date: Date(timeIntervalSince1970: $0.double(0)), freeBytes: $0.int(1)) }
        }
    }

    // MARK: Retention

    /// Deletes scans older than `keepDays`; beyond `fullResolutionDays` keeps only the last scan of each local day.
    public func prune(now: Date = Date(), keepDays: Int = 90, fullResolutionDays: Int = 7) throws {
        let expiry = now.addingTimeInterval(-Double(keepDays) * 86_400).timeIntervalSince1970
        let downsample = now.addingTimeInterval(-Double(fullResolutionDays) * 86_400).timeIntervalSince1970
        try locked {
            try database.transaction {
                try database.run("DELETE FROM scans WHERE time < ?", [.double(expiry)])
                try database.run("""
                DELETE FROM scans WHERE time < ?1 AND id NOT IN (
                    SELECT id FROM (
                        SELECT id, ROW_NUMBER() OVER (
                            PARTITION BY date(time, 'unixepoch', 'localtime') ORDER BY time DESC, id DESC
                        ) AS rank FROM scans WHERE time < ?1
                    ) WHERE rank = 1
                )
                """, [.double(downsample)])
            }
        }
    }

    // MARK: Watcher state

    public func stateValue(forKey key: String) throws -> String? {
        try locked {
            try database.query("SELECT value FROM watch_state WHERE key = ?", [.text(key)]) { $0.text(0) }.first
        }
    }

    public func setStateValue(_ value: String, forKey key: String) throws {
        try locked {
            try database.run("INSERT OR REPLACE INTO watch_state (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        }
    }
}
