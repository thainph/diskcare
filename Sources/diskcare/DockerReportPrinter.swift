import DiskCareCore
import Foundation

struct DockerReportPrinter {
    let report: DockerReport
    let top: Int

    func print() {
        guard report.available else {
            Swift.print("Docker unavailable: \(report.error ?? "unknown error")")
            return
        }
        let engine = report.engine
        Swift.print("""
        Docker \(engine?.version ?? "?") (API \(engine?.apiVersion ?? "?"))\
        \(engine?.platform.map { ", \($0)" } ?? "") via \(report.socketPath?.abbreviatingHome ?? "?")

        Reclaimable: \(ByteFormat.string(report.reclaimableBytes)) of \(ByteFormat.string(report.totalBytes))
        """)
        table(
            headers: ["TYPE", "TOTAL", "ACTIVE", "SIZE", "RECLAIMABLE"],
            rows: report.categories.map {
                [$0.category.title, "\($0.totalCount)", "\($0.activeCount)", ByteFormat.string($0.totalBytes), reclaimable($0)]
            },
            rightAligned: [1, 2, 3, 4]
        )

        let images = report.unusedImages.prefix(top)
        Swift.print("\nUnused images (no containers): \(report.unusedImages.count)")
        table(
            headers: ["SIZE", "UNIQUE", "AGE", "ID", "TAG"],
            rows: images.map {
                [ByteFormat.string($0.bytes), ByteFormat.string($0.uniqueBytes), age($0.createdAt), $0.shortID,
                 $0.isDangling ? "<dangling>" : $0.tags.joined(separator: ", ")]
            },
            rightAligned: [0, 1, 2]
        )

        Swift.print("\nUnused volumes (no containers)")
        if report.unusedVolumeGroups.isEmpty { Swift.print("  (none)") }
        for group in report.unusedVolumeGroups {
            let title = group.isAnonymous
                ? "anonymous (scratch, low risk)"
                : "\(group.composeProject.map { "project \($0)" } ?? "no compose project") (named, may hold data)"
            Swift.print("  \(title): \(group.volumes.count) volume\(group.volumes.count == 1 ? "" : "s"), \(ByteFormat.string(group.bytes))")
            table(
                headers: ["SIZE", "AGE", "NAME"],
                rows: group.volumes.prefix(top).map { [$0.bytes.map(ByteFormat.string) ?? "?", age($0.createdAt), $0.name] },
                rightAligned: [0, 1],
                indent: 4
            )
            if group.volumes.count > top { Swift.print("    … \(group.volumes.count - top) more") }
        }

        Swift.print("\nStopped containers: \(report.stoppedContainers.count)")
        table(
            headers: ["SIZE", "STOPPED", "STATE", "NAME", "IMAGE", "PROJECT"],
            rows: report.stoppedContainers.prefix(top).map {
                [ByteFormat.string($0.bytes), age($0.finishedAt ?? $0.createdAt), $0.state, $0.name, $0.image, $0.composeProject ?? "-"]
            },
            rightAligned: [0, 1]
        )

        let cache = report.buildCache
        Swift.print("""

        Build cache: \(cache.records) records (\(cache.inUse) in use), \(ByteFormat.string(cache.reclaimableBytes)) reclaimable\
        \(cache.lastUsedAt.map { ", last used \(age($0)) ago" } ?? "")
        """)
    }

    private func reclaimable(_ summary: DockerCategorySummary) -> String {
        let bytes = ByteFormat.string(summary.reclaimableBytes)
        guard summary.totalBytes > 0 else { return bytes }
        return "\(bytes) (\(Int((Double(summary.reclaimableBytes) / Double(summary.totalBytes) * 100).rounded()))%)"
    }

    private func age(_ date: Date?) -> String {
        guard let date else { return "-" }
        let seconds = max(0, Date().timeIntervalSince(date))
        switch seconds {
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}
