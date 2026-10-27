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
