import Foundation
import Testing
@testable import DiskCareCore

/// Thread-safe accumulator for callback results.
private final class Collected<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []

    func append(_ item: T) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    var all: [T] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    /// Polls until `condition` holds or `timeout` elapses (FSEvents latency varies under load).
    func wait(timeout: TimeInterval, until condition: ([T]) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition(all) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition(all)
    }
}

private func makeTemporaryDirectory() throws -> String {
    // The unresolved /var/folders spelling also checks the /private/var → /var path mapping.
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("diskcare-watch-\(UUID().uuidString)").path
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return ScanOptions.normalize(path)
}

private func write(_ path: String, bytes: Int) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
}

@Suite(.serialized) struct WatchTests {
    @Test func fsEventsReportsChangedDirectory() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/sub", withIntermediateDirectories: true)

        let batches = Collected<FSEventBatch>()
        let watcher = FSEventsWatcher(paths: [root], latency: 0.2) { batches.append($0) }
        #expect(watcher.start())
        defer { watcher.stop() }
        let startID = watcher.lastEventID

        // Give the stream a moment to attach before writing.
        try await Task.sleep(for: .milliseconds(300))
        try write(root + "/sub/file.bin", bytes: 4_096)

        let seen = await batches.wait(timeout: 20) { $0.contains { $0.directories.contains(root + "/sub") } }
        #expect(seen, "batches: \(batches.all.map(\.directories))")
        #expect(watcher.lastEventID > startID)
    }

    @Test func growthWatcherRemeasuresChangedArtifact() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/rust/Cargo.toml", bytes: 10)
        try write(root + "/rust/target/debug/a.bin", bytes: 100_000)
        try write(root + "/web/package.json", bytes: 10)
        try write(root + "/web/node_modules/x/index.js", bytes: 100_000)

        let report = await DiskAnalyzer.analyze(ScanOptions(roots: [root]), inspectGit: false)
        let target = root + "/rust/target"
        #expect(report.artifacts.contains { $0.path == target })

        var configuration = GrowthWatcher.Configuration()
        configuration.latency = 0.2
        configuration.settleSeconds = 0.3
        configuration.windowGrowthBytes = 2_000_000
        configuration.sizeThresholdBytes = 1_000_000_000
        let measurements = Collected<GrowthWatcher.Measurement>()
        let alerts = Collected<GrowthWatcher.Alert>()
        let watcher = GrowthWatcher(
            report: report, configuration: configuration,
            onMeasure: { $0.forEach(measurements.append) }, onAlert: alerts.append
        )
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        try write(target + "/debug/big.bin", bytes: 5_000_000)

        let alerted = await alerts.wait(timeout: 20) { $0.contains { $0.measurement.path == target } }
        #expect(alerted, "measurements: \(measurements.all.map { ($0.path, $0.bytes) })")
        let alert = try #require(alerts.all.first { $0.measurement.path == target })
        #expect(alert.measurement.kind == .cargoTarget)
        #expect(alert.measurement.bytes >= 5_000_000)
        if case .fastGrowth(let bytes, _) = alert.reason { #expect(bytes >= 4_900_000) } else { Issue.record("unexpected \(alert.reason)") }
        // Untouched artifacts report no change (fseventsd may still deliver the fixture's own creation events).
        #expect(measurements.all.filter { $0.path.hasSuffix("node_modules") }.allSatisfy { $0.bytes == $0.previousBytes })
    }

    @Test func growthWatcherDiscoversNewArtifact() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root + "/rust/Cargo.toml", bytes: 10)
        try write(root + "/rust/src/main.rs", bytes: 10)
        let report = await DiskAnalyzer.analyze(ScanOptions(roots: [root]), inspectGit: false)
        #expect(report.artifacts.isEmpty)

        var configuration = GrowthWatcher.Configuration()
        configuration.latency = 0.2
        configuration.settleSeconds = 0.3
        configuration.windowGrowthBytes = 2_000_000
        let alerts = Collected<GrowthWatcher.Alert>()
        let watcher = GrowthWatcher(
            report: report, configuration: configuration, excludedPaths: [root + "/ignored"], onAlert: alerts.append
        )
        #expect(watcher.start())
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))

        // A fresh `target/` after the scan, plus a non-artifact change and an excluded artifact that must be ignored.
        try write(root + "/rust/target/release/deps/lib.rlib", bytes: 3_000_000)
        try write(root + "/rust/src/more.rs", bytes: 3_000_000)
        try write(root + "/ignored/package.json", bytes: 10)
        try write(root + "/ignored/node_modules/x/blob", bytes: 3_000_000)

        let alerted = await alerts.wait(timeout: 20) { !$0.isEmpty }
        #expect(alerted)
        try await Task.sleep(for: .seconds(1))
        #expect(alerts.all.map(\.measurement.path) == [root + "/rust/target"])
        #expect(alerts.all.first?.measurement.baselineBytes == 0)
        #expect(watcher.trackedCount == 1)
    }
}
