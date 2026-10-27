import DiskCareCore
import Foundation

struct ReportPrinter {
    let report: ScanReport
    let top: Int
    let minimumBytes: Int64

    func print() {
        let stats = report.stats
        Swift.print("""
        Scanned \(report.roots.map(\.abbreviatingHome).joined(separator: ", "))
          \(stats.files.formatted()) files, \(stats.directories.formatted()) dirs, \(ByteFormat.string(stats.bytes)) \
        in \(String(format: "%.2f", stats.durationSeconds))s (git \(String(format: "%.2f", report.gitDurationSeconds))s)\
        \(stats.errors > 0 ? ", \(stats.errors) unreadable" : "")\
        \(stats.skippedOtherDevice > 0 ? ", \(stats.skippedOtherDevice) mounts skipped" : "")

        Regenerable artifacts: \(ByteFormat.string(report.regenerableBytes)) in \(report.artifacts.count) dirs
        """)

        table(
            headers: ["KIND", "COUNT", "SIZE", "RESTORE"],
            rows: report.kindSummaries.map { [$0.kind.rawValue, "\($0.count)", ByteFormat.string($0.bytes), $0.kind.restoreHint] },
            rightAligned: [1, 2]
        )

        let workspaces = report.workspaces.filter { $0.artifactBytes >= minimumBytes }.prefix(top)
        Swift.print("\nTop workspaces by reclaimable artifacts")
        table(
            headers: ["ARTIFACTS", "IDLE", "TYPE", "STATE", "BRANCH", "PATH"],
            rows: workspaces.map { workspace in
                [
                    ByteFormat.string(workspace.artifactBytes),
                    workspace.idleDays().map { "\($0)d" } ?? "-",
                    workspace.kind.rawValue,
                    state(of: workspace),
                    workspace.git?.branch ?? "-",
                    workspace.path.abbreviatingHome,
                ]
            },
            rightAligned: [0, 1]
        )

        let artifacts = report.artifacts.filter { $0.totals.bytes >= minimumBytes }.prefix(top)
        Swift.print("\nTop artifacts")
        table(
            headers: ["SIZE", "LINKED", "KIND", "PATH"],
            rows: artifacts.map {
                [
                    ByteFormat.string($0.totals.bytes),
                    $0.totals.hardlinkedBytes > 0 ? ByteFormat.string($0.totals.hardlinkedBytes) : "",
                    $0.kind.rawValue,
                    $0.path.abbreviatingHome,
                ]
            },
            rightAligned: [0, 1]
        )
    }

    private func state(of workspace: WorkspaceEntry) -> String {
        guard let git = workspace.git else { return "-" }
        var parts = [git.uncommittedChanges > 0 ? "dirty(\(git.uncommittedChanges))" : "clean"]
        if let merged = git.mergedInto { parts.append("merged→\(merged)") }
        return parts.joined(separator: " ")
    }
}
