import ArgumentParser
import DiskCareCore
import Foundation

struct History: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show free-space trend and the artifacts that grew the most (from recorded scans).",
        discussion: """
        Every `diskcare scan` is recorded (unless --no-record). The latest scan is compared
        with the scan closest to --days ago.
        """
    )

    @Option(name: .long, help: "Compare with the scan closest to this many days ago.")
    var days: Int = 7

    @Option(name: .long, help: "Rows to show in the growth table.")
    var top: Int = 15

    @Option(name: .long, help: "Hide growth smaller than this.")
    var minSize: String = "100MB"

    @Option(name: .long, help: "History database path.")
    var database: String = HistoryStore.defaultPath

    @Flag(name: .long, help: "Print the growth report as JSON.")
    var json = false

    func run() throws {
        let store = try HistoryStore(path: database)
        let report = try GrowthAnalyzer.analyze(store, days: days, minimumBytes: try parseSize(minSize))
        if json {
            try printJSON(report)
            return
        }
        guard let latest = report.latest else {
            print("No scans recorded yet. Run `diskcare scan` first.")
            return
        }
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        guard let baseline = report.baseline else {
            print("Only one scan covering \(latest.roots.map(\.abbreviatingHome).joined(separator: ", ")) (\(latest.scannedAt.formatted(dateStyle))). Scan again later to see growth.")
            printFreeSpace(report)
            return
        }
        print("""
        Growth \(baseline.scannedAt.formatted(dateStyle)) → \(latest.scannedAt.formatted(dateStyle)) \
        in \(latest.roots.map(\.abbreviatingHome).joined(separator: ", "))
          Regenerable artifacts: \(ByteFormat.string(baseline.regenerableBytes)) → \(ByteFormat.string(latest.regenerableBytes)) \
        (\(signed(latest.regenerableBytes - baseline.regenerableBytes)))
        """)
        printFreeSpace(report)

        print("\nGrowth alerts (≥ 5 GB, or ≥ 2 GB and doubled, or new ≥ 2 GB)")
        table(headers: ["GROWTH", "THEN", "NOW", "KIND", "PATH"], rows: report.alerts.prefix(top).map(row), rightAligned: [0, 1, 2])

        print("\nTop growth")
        table(headers: ["GROWTH", "THEN", "NOW", "KIND", "PATH"], rows: report.top.prefix(top).map(row), rightAligned: [0, 1, 2])
    }

    private func printFreeSpace(_ report: GrowthReport) {
        guard let first = report.freeSpace.first, let last = report.freeSpace.last else { return }
        var line = "  Free space: \(ByteFormat.string(first.freeBytes))"
        if let change = report.freeSpaceChange {
            line += " → \(ByteFormat.string(last.freeBytes)) (\(signed(change)), \(report.freeSpace.count) scans)"
        }
        print(line)
        // One point per day (last scan of the day) as a compact trend.
        let calendar = Calendar.current
        let daily = Dictionary(grouping: report.freeSpace) { calendar.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.last!.freeBytes) }
            .sorted { $0.0 < $1.0 }
        guard daily.count > 1 else { return }
        print("  " + daily.map { "\($0.0.formatted(.dateTime.month(.abbreviated).day())) \(ByteFormat.string($0.1))" }.joined(separator: " · "))
    }

    private func row(_ entry: GrowthEntry) -> [String] {
        [
            signed(entry.delta),
            entry.isNew ? "new" : ByteFormat.string(entry.bytesThen),
            ByteFormat.string(entry.bytesNow),
            entry.kind?.rawValue ?? "workspace",
            entry.path.abbreviatingHome,
        ]
    }
}

func signed(_ bytes: Int64) -> String {
    bytes < 0 ? "-" + ByteFormat.string(-bytes) : "+" + ByteFormat.string(bytes)
}
