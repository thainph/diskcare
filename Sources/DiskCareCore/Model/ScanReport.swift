import Foundation

public struct ArtifactEntry: Sendable, Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: ArtifactKind
    public let totals: Totals
    /// Enclosing git repository or worktree, if any.
    public let workspacePath: String?
    /// Latest source change in the directory that owns the artifact (used when there is no workspace).
    public let projectLastChangeAt: Date?
}

public enum WorkspaceKind: String, Sendable, Codable {
    case repository, worktree
}

/// A git repository or linked worktree: the unit a developer actually works in.
public struct WorkspaceEntry: Sendable, Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: WorkspaceKind
    public let mainRepositoryPath: String?
    public let totals: Totals
    public let artifactBytes: Int64
    public let artifactCount: Int
    public let lastSourceChangeAt: Date?
    public var git: GitInfo?

    /// Last human activity. For git workspaces file mtimes are noisy (checkout, `terraform init`,
    /// IDE metadata), so only commits/checkouts count, plus file changes when the tree is dirty.
    public var lastActivityAt: Date? {
        guard let git else { return lastSourceChangeAt }
        let dirtyChange = git.uncommittedChanges > 0 ? lastSourceChangeAt : nil
        return [git.lastCommitAt, git.lastHeadMoveAt, dirtyChange].compactMap { $0 }.max() ?? lastSourceChangeAt
    }

    public func idleDays(now: Date = Date()) -> Int? {
        lastActivityAt.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}

public struct KindSummary: Sendable, Codable, Identifiable {
    public var id: ArtifactKind { kind }
    public let kind: ArtifactKind
    public let count: Int
    public let bytes: Int64
}

public struct ScanReport: Sendable, Codable {
    public let roots: [String]
    public let scannedAt: Date
    public let stats: ScanStats
    public let gitDurationSeconds: Double
    /// Sorted by size, largest first. Excludes `.git` metadata.
    public let artifacts: [ArtifactEntry]
    /// Sorted by regenerable artifact size, largest first.
    public let workspaces: [WorkspaceEntry]

    public var regenerableBytes: Int64 { artifacts.reduce(0) { $0 + $1.totals.bytes } }

    public var kindSummaries: [KindSummary] {
        Dictionary(grouping: artifacts, by: \.kind)
            .map { KindSummary(kind: $0.key, count: $0.value.count, bytes: $0.value.reduce(0) { $0 + $1.totals.bytes }) }
            .sorted { $0.bytes > $1.bytes }
    }
}

extension ScanReport {
    /// Replaces everything under `root` with a fresh single-root report, keeping the other roots'
    /// (older) results. Lets the app scan roots one by one and update the UI progressively.
    public func replacing(root: String, with fresh: ScanReport) -> ScanReport {
        let prefix = root == "/" ? "/" : root + "/"
        func isUnder(_ path: String) -> Bool { path == root || path.hasPrefix(prefix) }
        // Interim result: stats stay those of the last complete pass (see `combining`).
        return ScanReport(
            roots: Array(Set(roots + fresh.roots)).sorted(),
            scannedAt: fresh.scannedAt,
            stats: stats,
            gitDurationSeconds: gitDurationSeconds + fresh.gitDurationSeconds,
            artifacts: (artifacts.filter { !isUnder($0.path) } + fresh.artifacts).sorted { $0.totals.bytes > $1.totals.bytes },
            workspaces: (workspaces.filter { !isUnder($0.path) } + fresh.workspaces).sorted { $0.artifactBytes > $1.artifactBytes }
        )
    }

    /// Combines single-root reports from one scan pass.
    public static func combining(_ reports: [ScanReport]) -> ScanReport? {
        guard var combined = reports.first else { return nil }
        for report in reports.dropFirst() {
            var stats = combined.stats
            stats.add(report.stats)
            stats.bytes += report.stats.bytes
            stats.durationSeconds += report.stats.durationSeconds
            combined = ScanReport(
                roots: combined.roots + report.roots,
                scannedAt: report.scannedAt,
                stats: stats,
                gitDurationSeconds: combined.gitDurationSeconds + report.gitDurationSeconds,
                artifacts: (combined.artifacts + report.artifacts).sorted { $0.totals.bytes > $1.totals.bytes },
                workspaces: (combined.workspaces + report.workspaces).sorted { $0.artifactBytes > $1.artifactBytes }
            )
        }
        return combined
    }
}
