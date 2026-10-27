import ArgumentParser
import DiskCareCore
import Foundation

struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Watch directories with FSEvents and print artifact growth as it happens (Ctrl-C to stop).",
        discussion: """
        Scans the paths once, then re-measures only the artifacts that change.
        Example (quick manual test):
          diskcare watch /tmp/demo --growth 100MB --latency 1 --settle 2
        """
    )

    @Argument(help: "Directories to watch.")
    var paths: [String]

    @Option(name: .long, help: "Alert when an artifact grows past this size.")
    var threshold: String = "20GB"

    @Option(name: .long, help: "Alert when an artifact grows this much within --window.")
    var growth: String = "5GB"

    @Option(name: .long, help: "Growth window in minutes.")
    var window: Double = 60

    @Option(name: .long, help: "FSEvents latency in seconds.")
    var latency: Double = 10

    @Option(name: .long, help: "Seconds of quiet before re-measuring a changed artifact.")
    var settle: Double = 20

    @Option(name: .long, help: "Exclude a path (repeatable).")
    var exclude: [String] = []

    @Flag(name: .long, help: "Do not track artifacts created after the initial scan.")
    var noDiscover = false

    func run() throws {
        var configuration = GrowthWatcher.Configuration()
        configuration.sizeThresholdBytes = try parseSize(threshold)
        configuration.windowGrowthBytes = try parseSize(growth)
        configuration.windowSeconds = window * 60
        configuration.latency = latency
        configuration.settleSeconds = settle
        configuration.discoverNewArtifacts = !noDiscover
        configuration.replayFromLastRun = false

        let report = DiskAnalyzer.analyze(ScanOptions(roots: paths, excludedPaths: Set(exclude)), inspectGit: false)
        let watcher = GrowthWatcher(
            report: report, configuration: configuration, excludedPaths: Set(exclude),
            onMeasure: { measurements in
                for item in measurements {
                    log("\(signed(item.bytes - item.previousBytes).padding(toLength: 9))  now \(ByteFormat.string(item.bytes).padding(toLength: 8))  \(item.kind.rawValue)  \(item.path.abbreviatingHome)")
                }
            },
            onAlert: { alert in log("ALERT  \(alert.message)") }
        )
        guard watcher.start() else { throw ValidationError("Could not start FSEvents stream for \(paths.joined(separator: ", "))") }
        log("Watching \(report.roots.map(\.abbreviatingHome).joined(separator: ", ")): \(report.artifacts.count) artifacts (\(ByteFormat.string(report.regenerableBytes))), alert at \(ByteFormat.string(configuration.sizeThresholdBytes)) or +\(ByteFormat.string(configuration.windowGrowthBytes))/\(Int(window)) min")
        withExtendedLifetime(watcher) { dispatchMain() }
    }
}

private func log(_ message: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("\(time)  \(message)")
    fflush(stdout)
}

private extension String {
    func padding(toLength length: Int) -> String {
        count >= length ? self : self + String(repeating: " ", count: length - count)
    }
}
