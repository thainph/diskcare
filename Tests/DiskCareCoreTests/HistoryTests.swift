import Foundation
import Testing
@testable import DiskCareCore

private func temporaryDatabase() -> String {
    FileManager.default.temporaryDirectory.appendingPathComponent("diskcare-history-\(UUID().uuidString)/history.sqlite").path
}

private func removeDatabase(_ path: String) {
    try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
}

private func makeReport(roots: [String], at date: Date, artifacts: [(String, ArtifactKind, Int64)], workspaces: [(String, Int64)] = []) -> ScanReport {
    func totals(_ bytes: Int64) -> Totals {
        var totals = Totals()
        totals.bytes = bytes
        return totals
    }
    var stats = ScanStats()
    stats.bytes = artifacts.reduce(0) { $0 + $1.2 }
    return ScanReport(
        roots: roots, scannedAt: date, stats: stats, gitDurationSeconds: 0,
        artifacts: artifacts.map {
            ArtifactEntry(path: $0.0, kind: $0.1, totals: totals($0.2), workspacePath: nil, projectLastChangeAt: nil)
        },
        workspaces: workspaces.map {
            WorkspaceEntry(
                path: $0.0, kind: .repository, mainRepositoryPath: nil, totals: totals($0.1),
                artifactBytes: 0, artifactCount: 0, lastSourceChangeAt: nil
            )
        }
    )
}

private let GB: Int64 = 1_000_000_000
private let day: TimeInterval = 86_400

@Suite struct HistoryStoreTests {
    @Test func recordsAndReadsBack() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        let report = makeReport(
            roots: ["/w"], at: now,
            artifacts: [("/w/a/target", .cargoTarget, 3 * GB), ("/w/b/node_modules", .nodeModules, 500), ("/w/c/.terraform", .terraform, 2 * GB)],
            workspaces: [("/w/a", 4 * GB)]
        )
        let record = try store.record(report: report, freeBytes: 50 * GB, dockerBytes: 7 * GB)

        let scans = try store.scans()
        #expect(scans == [record])
        #expect(record.roots == ["/w"])
        #expect(record.freeBytes == 50 * GB)
        #expect(record.dockerBytes == 7 * GB)
        #expect(record.artifactCount == 3)
        #expect(record.regenerableBytes == 5 * GB + 500)
        #expect(abs(record.scannedAt.timeIntervalSince(now)) < 0.001)

        let sizes = try store.artifactSizes(scanID: record.id)
        #expect(sizes.count == 2, "artifacts below minimumStoredBytes are not stored")
        #expect(sizes["/w/a/target"]?.bytes == 3 * GB)
        #expect(sizes["/w/a/target"]?.kind == .cargoTarget)
        #expect(try store.workspaceSizes(scanID: record.id) == ["/w/a": 4 * GB])
        #expect(try store.freeSpaceSeries(since: now.addingTimeInterval(-60)) == [FreeSpacePoint(date: record.scannedAt, freeBytes: 50 * GB)])

        // Reopening sees the same data (schema migration is idempotent).
        let reopened = try HistoryStore(path: path)
        #expect(try reopened.latestScan() == record)
    }

    @Test func growthBetweenBaselineAndLatest() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        try store.record(report: makeReport(roots: ["/w"], at: now - 10 * day, artifacts: [("/w/a/target", .cargoTarget, 1 * GB)]), freeBytes: 100 * GB)
        try store.record(report: makeReport(roots: ["/w"], at: now - 7.2 * day, artifacts: [("/w/a/target", .cargoTarget, 2 * GB), ("/w/old/node_modules", .nodeModules, 1 * GB)]), freeBytes: 90 * GB)
        try store.record(report: makeReport(roots: ["/w"], at: now - 3 * day, artifacts: [("/w/a/target", .cargoTarget, 30 * GB)]), freeBytes: 60 * GB)
        // Narrower scan in between (other roots) must not become the baseline.
        try store.record(report: makeReport(roots: ["/w/a"], at: now - 1 * day, artifacts: [("/w/a/target", .cargoTarget, 40 * GB)]), freeBytes: 55 * GB)
        try store.record(report: makeReport(roots: ["/w"], at: now, artifacts: [
            ("/w/a/target", .cargoTarget, 66 * GB),
            ("/w/new/.venv", .pythonVenv, 3 * GB),
            ("/w/old/node_modules", .nodeModules, 1 * GB),
        ]), freeBytes: 20 * GB)

        let latest = try #require(try store.latestScan())
        let baseline = try #require(try store.baselineScan(for: now - 7 * day, before: latest))
        #expect(abs(baseline.scannedAt.timeIntervalSince(now - 7.2 * day)) < 1, "last scan at or before the target date")

        let entries = try store.growth(since: now - 7 * day, minimumBytes: 1)
        #expect(entries.map(\.path) == ["/w/a/target", "/w/new/.venv"])
        #expect(entries[0].bytesThen == 2 * GB && entries[0].bytesNow == 66 * GB && entries[0].delta == 64 * GB && !entries[0].isNew)
        #expect(entries[1].isNew && entries[1].bytesThen == 0)

        #expect(try store.growth(since: now - 7 * day, minimumBytes: 10 * GB).count == 1)
        // A narrow latest scan only compares against scans covering it.
        let series = try store.freeSpaceSeries(since: now - 8 * day)
        #expect(series.map(\.freeBytes) == [90 * GB, 60 * GB, 55 * GB, 20 * GB])
    }

    @Test func pathsOutsideBaselineRootsAreNotNew() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        try store.record(report: makeReport(roots: ["/w/a"], at: now - day, artifacts: [("/w/a/target", .cargoTarget, 1 * GB)]), freeBytes: nil)
        try store.record(report: makeReport(roots: ["/w/a"], at: now, artifacts: [("/w/a/target", .cargoTarget, 2 * GB)]), freeBytes: nil)
        let baseline = try #require(try store.scans().first)
        let wider = try store.record(report: makeReport(roots: ["/w"], at: now + 1, artifacts: [
            ("/w/a/target", .cargoTarget, 3 * GB), ("/w/b/target", .cargoTarget, 9 * GB),
        ]), freeBytes: nil)
        let entries = try store.growth(from: baseline, to: wider)
        #expect(entries.map(\.path) == ["/w/a/target"], "/w/b was never scanned before, so it is not 'new'")
    }

    @Test func retentionPrunesAndDownsamples() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let calendar = Calendar.current
        let now = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        func at(daysAgo: Int, hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now.addingTimeInterval(-Double(daysAgo) * day))!
        }
        let dates = [
            at(daysAgo: 120, hour: 10),                              // expired
            at(daysAgo: 30, hour: 9), at(daysAgo: 30, hour: 15),     // downsampled to the 15:00 one
            at(daysAgo: 20, hour: 11),                               // only scan that day: kept
            at(daysAgo: 2, hour: 8), at(daysAgo: 2, hour: 9),        // recent: all kept
        ]
        for date in dates {
            // Insert out of order on purpose; record() prunes with the real clock, so 120d is dropped immediately.
            try store.record(report: makeReport(roots: ["/w"], at: date, artifacts: [("/w/t", .cargoTarget, GB)]), freeBytes: GB)
        }
        try store.prune(now: now, keepDays: 90, fullResolutionDays: 7)
        let kept = try store.scans().map(\.scannedAt)
        #expect(kept == [dates[2], dates[3], dates[4], dates[5]])

        // Artifact rows of deleted scans are gone too (ON DELETE CASCADE).
        let orphanCheck = try HistoryStore(path: path)
        let ids = try orphanCheck.scans().map(\.id)
        let maxDeleted = ids.min()! - 1
        #expect(try orphanCheck.artifactSizes(scanID: maxDeleted).isEmpty)
    }

    @Test func watchStateRoundTrip() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        #expect(try store.stateValue(forKey: "k") == nil)
        try store.setStateValue("42", forKey: "k")
        try store.setStateValue("43", forKey: "k")
        #expect(try store.stateValue(forKey: "k") == "43")
    }
}

@Suite struct GrowthAnalyzerTests {
    private func entry(_ then: Int64, _ now: Int64, new: Bool = false) -> GrowthEntry {
        GrowthEntry(path: "/p", kind: .cargoTarget, bytesThen: then, bytesNow: now, isNew: new, since: Date(), until: Date())
    }

    @Test func thresholds() {
        let thresholds = GrowthThresholds()
        #expect(thresholds.isSignificant(entry(60 * GB, 65 * GB)), "≥ 5 GB absolute")
        #expect(!thresholds.isSignificant(entry(60 * GB, 64 * GB)), "4 GB on 60 GB is neither absolute nor relative")
        #expect(thresholds.isSignificant(entry(2 * GB, 4 * GB)), "+2 GB and doubled")
        #expect(!thresholds.isSignificant(entry(3 * GB, 5 * GB)), "+2 GB but only +67%")
        #expect(!thresholds.isSignificant(entry(500_000_000, 2_400_000_000)), "+380% but under 2 GB")
        #expect(thresholds.isSignificant(entry(0, 2 * GB, new: true)), "new and ≥ 2 GB")
        #expect(!thresholds.isSignificant(entry(0, 1 * GB, new: true)), "new but small")
    }

    @Test func analyzeUsesStoreAndThresholds() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let store = try HistoryStore(path: path)
        let now = Date()
        try store.record(report: makeReport(roots: ["/w"], at: now - 7 * day, artifacts: [
            ("/w/a/target", .cargoTarget, 10 * GB), ("/w/b/node_modules", .nodeModules, 1 * GB),
        ]), freeBytes: 80 * GB)
        try store.record(report: makeReport(roots: ["/w"], at: now, artifacts: [
            ("/w/a/target", .cargoTarget, 66 * GB), ("/w/b/node_modules", .nodeModules, 1_200_000_000),
            ("/w/c/node_modules", .nodeModules, 50_000_000),
        ]), freeBytes: 20 * GB)

        let report = try GrowthAnalyzer.analyze(store, days: 7, now: now)
        #expect(report.alerts.map(\.path) == ["/w/a/target"])
        #expect(report.top.map(\.path) == ["/w/a/target", "/w/b/node_modules"], "growth under 100 MB is hidden")
        #expect(report.freeSpaceChange == -60 * GB)
    }

    @Test func emptyHistory() throws {
        let path = temporaryDatabase()
        defer { removeDatabase(path) }
        let report = try GrowthAnalyzer.analyze(try HistoryStore(path: path))
        #expect(report.latest == nil && report.baseline == nil && report.top.isEmpty)
    }

    @Test func windowGrowth() {
        let now = Date()
        let hour: TimeInterval = 3_600
        // Smallest sample inside the window.
        #expect(GrowthWatcher.windowGrowth(samples: [(now - 2 * hour, 0), (now - 0.5 * hour, 10 * GB), (now, 16 * GB)], now: now, window: hour) == 6 * GB)
        // Only an older sample: average rate scaled to the window (12 GB over 4 h → 3 GB/h).
        #expect(GrowthWatcher.windowGrowth(samples: [(now - 4 * hour, 0), (now, 12 * GB)], now: now, window: hour) == 3 * GB)
        #expect(GrowthWatcher.windowGrowth(samples: [(now - 600, 5 * GB), (now, 1 * GB)], now: now, window: hour) == 0)
        #expect(GrowthWatcher.windowGrowth(samples: [(now, 1 * GB)], now: now, window: hour) == 0)
    }
}
