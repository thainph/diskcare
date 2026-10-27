import Foundation

public struct ArtifactEntry: Sendable, Codable, Identifiable {
    public var id: String { path }
    public let path: String
    public let kind: ArtifactKind
    public let totals: Totals
    /// Enclosing git repository or worktree, if any.
    public let workspacePath: String?
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

    /// Latest of last commit and last source-file change.
    public var lastActivityAt: Date? {
        [git?.lastCommitAt, lastSourceChangeAt].compactMap { $0 }.max()
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
