import Foundation
import Testing
@testable import DiskCareCore

private func temporaryDatabase() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("diskcare-history-\(UUID().uuidString)/history.sqlite").path
}

private func removeDatabase(_ path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

private let GB: Int64 = 1_000_000_000
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

private func cacheReport(at date: Date, _ sizes: [(String, Int64)]) -> CacheReport {
    CacheReport(scannedAt: date, durationSeconds: 0, entries: sizes.map { id, bytes in
        CacheEntry(
            id: id, title: id.capitalized, category: .build, safety: .regenerable, paths: ["/c/\(id)"], bytes: bytes,
            hardlinkedBytes: 0, files: 1, lastModifiedAt: nil, method: .deleteContents, command: nil, nativeCommand: nil,
            fallback: .deleteContents, note: nil, items: []
        )
    })
}

private func userVersion(_ path: String) throws -> Int64 {
    try SQLiteDatabase(path: path).query("PRAGMA user_version") { $0.int(0) }.first ?? -1
}

@Suite struct HistoryMigrationTests {
    /// The schema as shipped in v0.1.x (schema version 1), frozen here on purpose.
    private static let version1Schema = """
    CREATE TABLE scans (
        id INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL, roots TEXT NOT NULL,
        scanned_bytes INTEGER NOT NULL, regenerable_bytes INTEGER NOT NULL, artifact_count INTEGER NOT NULL,
        free_bytes INTEGER, docker_bytes INTEGER
    );
    CREATE INDEX scans_time ON scans(time);
    CREATE TABLE artifact_sizes (
        scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
        path TEXT NOT NULL, kind TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY (scan_id, path)
    ) WITHOUT ROWID;
    CREATE TABLE workspace_sizes (
        scan_id INTEGER NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
        path TEXT NOT NULL, bytes INTEGER NOT NULL, artifact_bytes INTEGER NOT NULL, PRIMARY KEY (scan_id, path)
    ) WITHOUT ROWID;
    CREATE TABLE watch_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    PRAGMA user_version = 1;
    """

    @Test func migratesVersion1DatabaseKeepingData() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let scanTime = Date().addingTimeInterval(-hour).timeIntervalSince1970
        do {
            let old = try SQLiteDatabase(path: path)
            try old.execute(Self.version1Schema)
            try old.run(
                "INSERT INTO scans (time, roots, scanned_bytes, regenerable_bytes, artifact_count, free_bytes, docker_bytes) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [.double(scanTime), .text(#"["/w"]"#), .int(10 * GB), .int(3 * GB), .int(1), .int(80 * GB), .null]
            )
            try old.run("INSERT INTO artifact_sizes (scan_id, path, kind, bytes) VALUES (1, '/w/a/target', 'cargo-target', ?)", [.int(3 * GB)])
            try old.run("INSERT INTO watch_state (key, value) VALUES ('fsevents', '123')")
        }
        #expect(try userVersion(path) == 1)

        let store = try HistoryStore(path: path)
        #expect(try userVersion(path) == HistoryStore.schemaVersion)
        #expect(HistoryStore.schemaVersion == 2)

        let scans = try store.scans()
        #expect(scans.count == 1)
        #expect(scans.first?.freeBytes == 80 * GB, "free_bytes keeps its meaning and value")
        #expect(scans.first?.roots == ["/w"])
        #expect(try store.artifactSizes(scanID: 1)["/w/a/target"]?.bytes == 3 * GB)
        #expect(try store.stateValue(forKey: "fsevents") == "123")

        // New v2 tables work.
        try store.record(sample: FreeSample(date: Date(), availableBytes: 70 * GB, importantBytes: 75 * GB, volumeUsedBytes: nil))
        #expect(try store.freeSamples().map(\.availableBytes) == [70 * GB])
        try store.record(caches: cacheReport(at: Date(), [("homebrew", 2 * GB)]))
        #expect(try store.cacheScans().count == 1)

        // Reopening a current database is a no-op.
        _ = try HistoryStore(path: path)
        #expect(try store.scans().count == 1)
        #expect(try userVersion(path) == 2)
    }

    @Test func newerSchemaIsLeftAlone() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        _ = try HistoryStore(path: path)
        try SQLiteDatabase(path: path).execute("PRAGMA user_version = 99")
        _ = try HistoryStore(path: path)
        #expect(try userVersion(path) == 99)
    }
}

@Suite struct FreeSampleHistoryTests {
    @Test func roundTripsSamples() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        let space = VolumeSpace(totalBytes: 500 * GB, availableBytes: 100 * GB, importantAvailableBytes: 110 * GB, volumeUsedBytes: 300 * GB)
        try store.record(sample: FreeSample(date: now, space: space))
        let sample = try #require(try store.freeSamples().first)
        #expect(sample.availableBytes == 100 * GB)
        #expect(sample.importantBytes == 110 * GB)
        #expect(sample.volumeUsedBytes == 300 * GB)
        #expect(abs(sample.date.timeIntervalSince(now)) < 0.001)
    }

    @Test func keeps90DaysAndDownsamplesToHourlyAfter7Days() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        // Start of an hour 10 days ago (hour buckets are UTC hours since the epoch).
        func startOfHour(_ time: TimeInterval) -> TimeInterval { time - time.truncatingRemainder(dividingBy: hour) }
        let oldHour = startOfHour(now.timeIntervalSince1970 - 10 * day)
        let recentHour = startOfHour(now.timeIntervalSince1970 - 2 * day)
        let times: [TimeInterval] = [
            now.timeIntervalSince1970 - 100 * day,              // expired
            oldHour + 300, oldHour + 1200, oldHour + 3000,      // one old hour: keep the last
            oldHour + hour + 600,                               // next old hour: kept
            recentHour + 300, recentHour + 1200, recentHour + 2100,  // recent: all kept
        ]
        for (index, time) in times.enumerated() {
            try store.record(sample: FreeSample(date: Date(timeIntervalSince1970: time), availableBytes: Int64(index) * GB))
        }
        try store.prune(now: now)
        #expect(try store.freeSamples().map(\.availableBytes) == [3, 4, 5, 6, 7].map { $0 * GB })
    }
}

@Suite struct CacheSizeHistoryTests {
    @Test func cacheGrowthAgainstBaseline() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        try store.record(caches: cacheReport(at: now - 9 * day, [("homebrew", 1 * GB), ("cargo", 1 * GB)]))
        try store.record(caches: cacheReport(at: now - 6 * day, [("homebrew", 2 * GB), ("cargo", 5 * GB)]))
        try store.record(caches: cacheReport(at: now - hour, [("homebrew", 4 * GB), ("cargo", 4 * GB), ("pnpm", 3 * GB)]))

        // Baseline for 7 days ago: the scan 9 days ago (last at or before it).
        let growth = try store.cacheGrowth(since: now - 7 * day)
        #expect(growth.map(\.name) == ["cargo", "homebrew", "pnpm"])
        #expect(growth.map(\.delta) == [3 * GB, 3 * GB, 3 * GB])
        #expect(growth.allSatisfy { $0.origin == .cache })
        // Baseline 2 days ago: the scan 6 days ago; cargo shrank.
        #expect(try store.cacheGrowth(since: now - 2 * day, minimumBytes: GB).map(\.name) == ["pnpm", "homebrew"])
    }

    @Test func fastestGrowingMergesArtifactsAndCaches() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        func scan(_ date: Date, _ target: Int64, _ modules: Int64) -> ScanReport {
            var stats = ScanStats()
            stats.bytes = target + modules
            func totals(_ bytes: Int64) -> Totals {
                var totals = Totals()
                totals.bytes = bytes
                return totals
            }
            return ScanReport(
                roots: ["/w"], scannedAt: date, stats: stats, gitDurationSeconds: 0,
                artifacts: [
                    ArtifactEntry(path: "/w/a/target", kind: .cargoTarget, totals: totals(target), workspacePath: nil, projectLastChangeAt: nil),
                    ArtifactEntry(path: "/w/b/node_modules", kind: .nodeModules, totals: totals(modules), workspacePath: nil, projectLastChangeAt: nil),
                ],
                workspaces: []
            )
        }
        try store.record(report: scan(now - 8 * day, 10 * GB, 1 * GB), freeBytes: nil)
        try store.record(report: scan(now - hour, 30 * GB, 2 * GB), freeBytes: nil)
        try store.record(caches: cacheReport(at: now - 8 * day, [("homebrew", 1 * GB), ("pnpm", 1 * GB)]))
        try store.record(caches: cacheReport(at: now - hour, [("homebrew", 6 * GB), ("pnpm", 1 * GB + 50_000_000)]))

        let top = try GrowthAnalyzer.fastestGrowing(store, days: 7, limit: 3, now: now)
        #expect(top.map(\.id) == ["artifact:/w/a/target", "cache:homebrew", "artifact:/w/b/node_modules"])
        #expect(top.map(\.delta) == [20 * GB, 5 * GB, 1 * GB])
    }

    @Test func pruneDownsamplesCacheScansDaily() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        let calendar = Calendar.current
        let oldDay = calendar.startOfDay(for: now - 20 * day)
        for date in [now - 100 * day, oldDay + 8 * hour, oldDay + 9 * hour, now - day, now - hour] {
            try store.record(caches: cacheReport(at: date, [("homebrew", GB)]))
        }
        try store.prune(now: now)
        let kept = try store.cacheScans().map(\.date.timeIntervalSince1970)
        #expect(kept.count == 3)
        #expect(abs(kept[0] - (oldDay + 9 * hour).timeIntervalSince1970) < 0.001)
        // Sizes of deleted cache scans are gone (ON DELETE CASCADE).
        #expect(try store.cacheSizes(scanID: 1).isEmpty)
    }
}
