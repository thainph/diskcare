import Foundation
import Testing
@testable import DiskCareCore

private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

@Suite struct ScanFreshnessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func stalenessLevels() {
        #expect(ScanFreshness.staleness(lastScan: nil, now: now) == .never)
        #expect(ScanFreshness.staleness(lastScan: now - hour, now: now) == .fresh)
        #expect(ScanFreshness.staleness(lastScan: now - 2 * day, now: now) == .fresh)
        #expect(ScanFreshness.staleness(lastScan: now - 2 * day - 60, now: now) == .aging)
        #expect(ScanFreshness.staleness(lastScan: now - 7 * day, now: now) == .aging)
        #expect(ScanFreshness.staleness(lastScan: now - 7 * day - 60, now: now) == .stale)
    }

    @Test func scanIsDueAfterTwiceTheInterval() {
        #expect(ScanFreshness.isScanDue(lastScan: nil, intervalHours: 6, now: now))
        #expect(!ScanFreshness.isScanDue(lastScan: now - 11 * hour, intervalHours: 6, now: now))
        #expect(!ScanFreshness.isScanDue(lastScan: now - 12 * hour, intervalHours: 6, now: now))
        #expect(ScanFreshness.isScanDue(lastScan: now - 12 * hour - 60, intervalHours: 6, now: now))
        #expect(ScanFreshness.isScanDue(lastScan: now - 3 * hour, intervalHours: 1, now: now))
        // A nonsensical interval is treated as one hour.
        #expect(ScanFreshness.isScanDue(lastScan: now - 3 * hour, intervalHours: 0, now: now))
        // Clock moved backwards: not due.
        #expect(!ScanFreshness.isScanDue(lastScan: now + hour, intervalHours: 6, now: now))
    }

    @Test func ageText() {
        #expect(ScanFreshness.ageText(lastScan: now - 59 * 60, now: now) == "just now")
        #expect(ScanFreshness.ageText(lastScan: now - hour, now: now) == "1 hour ago")
        #expect(ScanFreshness.ageText(lastScan: now - 5.5 * hour, now: now) == "5 hours ago")
        #expect(ScanFreshness.ageText(lastScan: now - day, now: now) == "1 day ago")
        #expect(ScanFreshness.ageText(lastScan: now - 12.9 * day, now: now) == "12 days ago")
        #expect(ScanFreshness.ageText(lastScan: now + hour, now: now) == "just now")
    }

    @Test func doctorResult() {
        func record(_ date: Date) -> ScanRecord {
            ScanRecord(id: 1, scannedAt: date, roots: ["/w"], scannedBytes: 0, regenerableBytes: 0, artifactCount: 0, freeBytes: nil, dockerBytes: nil)
        }
        #expect(ScanFreshness.checkResult(lastScan: nil, now: now).status == .info)
        #expect(ScanFreshness.checkResult(lastScan: record(now - day), now: now).status == .ok)
        #expect(ScanFreshness.checkResult(lastScan: record(now - 3 * day), now: now).status == .info)
        let stale = ScanFreshness.checkResult(lastScan: record(now - 10 * day), now: now)
        #expect(stale.status == .warning)
        #expect(stale.id == "scan-freshness")
        #expect(stale.finding.hasPrefix("Last scan 10 days ago (/w)."))
        #expect(stale.fix != nil)
    }

    @Test func doctorResultFromRecordedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diskcare-fresh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try HistoryStore(path: directory.appendingPathComponent("history.sqlite").path)
        // Real clock: record() prunes relative to now.
        let now = Date()
        try store.record(
            report: ScanReport(roots: ["/w"], scannedAt: now - 8 * day, stats: ScanStats(), gitDurationSeconds: 0, artifacts: [], workspaces: []),
            freeBytes: nil
        )
        #expect(ScanFreshness.checkResult(lastScan: try store.latestScan(), now: now).status == .warning)
    }
}
