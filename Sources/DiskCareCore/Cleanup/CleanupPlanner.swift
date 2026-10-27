import Foundation

public struct CleanupCriteria: Sendable {
    /// nil = every regenerable kind.
    public var kinds: Set<ArtifactKind>?
    public var minimumIdleDays: Int
    public var minimumBytes: Int64
    /// Also clean workspaces with uncommitted changes (still subject to idle days).
    public var includeDirty: Bool
    /// Only clean workspaces whose HEAD is already merged into a base branch.
    public var mergedOnly: Bool
    /// Remove whole linked worktrees that are clean, merged and idle (`git worktree remove`).
    public var removeMergedWorktrees: Bool

    public init(
        kinds: Set<ArtifactKind>? = nil, minimumIdleDays: Int = 30, minimumBytes: Int64 = 1_000_000,
        includeDirty: Bool = false, mergedOnly: Bool = false, removeMergedWorktrees: Bool = false
    ) {
        self.kinds = kinds
        self.minimumIdleDays = minimumIdleDays
        self.minimumBytes = minimumBytes
        self.includeDirty = includeDirty
        self.mergedOnly = mergedOnly
        self.removeMergedWorktrees = removeMergedWorktrees
    }
}

public enum CleanupAction: String, Sendable, Codable {
    /// Delete a regenerable artifact directory.
    case deleteArtifact
    /// `git worktree remove` a clean, merged linked worktree (its branch is kept).
    case removeWorktree
}

public struct CleanupCandidate: Sendable, Codable, Identifiable {
    public var id: String { path }
    public let action: CleanupAction
    public let path: String
    /// Artifact kind, or nil for worktree removal.
    public let kind: ArtifactKind?
    public let bytes: Int64
    public let hardlinkedBytes: Int64
    public let idleDays: Int?
    public let workspacePath: String?
    public let mainRepositoryPath: String?
    public let reason: String
}

public enum CleanupPlanner {
    public static func plan(_ report: ScanReport, criteria: CleanupCriteria, now: Date = Date()) -> [CleanupCandidate] {
        let workspaces = Dictionary(report.workspaces.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var candidates: [CleanupCandidate] = []
        var removedWorktrees: [String] = []

        if criteria.removeMergedWorktrees {
            for workspace in report.workspaces where workspace.kind == .worktree {
                guard let git = workspace.git, git.uncommittedChanges == 0, let merged = git.mergedInto,
                      workspace.mainRepositoryPath != nil,
                      let idle = workspace.idleDays(now: now), idle >= criteria.minimumIdleDays,
                      workspace.totals.bytes >= criteria.minimumBytes else { continue }
                removedWorktrees.append(workspace.path + "/")
                candidates.append(CleanupCandidate(
                    action: .removeWorktree, path: workspace.path, kind: nil,
                    bytes: workspace.totals.bytes, hardlinkedBytes: workspace.totals.hardlinkedBytes,
                    idleDays: idle, workspacePath: workspace.path, mainRepositoryPath: workspace.mainRepositoryPath,
                    reason: "worktree clean, merged into \(merged), idle \(idle)d"
                ))
            }
        }

        for artifact in report.artifacts {
            guard artifact.kind.isRegenerable,
                  criteria.kinds?.contains(artifact.kind) ?? true,
                  artifact.totals.bytes >= criteria.minimumBytes,
                  !removedWorktrees.contains(where: { artifact.path.hasPrefix($0) }) else { continue }

            let workspace = artifact.workspacePath.flatMap { workspaces[$0] }
            let lastActivity = workspace?.lastActivityAt ?? artifact.projectLastChangeAt
            let idle = lastActivity.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
            guard let idle, idle >= criteria.minimumIdleDays else { continue }

            var reasons = ["idle \(idle)d"]
            if let git = workspace?.git {
                if git.uncommittedChanges > 0 {
                    guard criteria.includeDirty else { continue }
                    reasons.append("dirty")
                }
                if let merged = git.mergedInto {
                    reasons.append("merged into \(merged)")
                } else if criteria.mergedOnly {
                    continue
                }
            } else if criteria.mergedOnly {
                continue
            }

            candidates.append(CleanupCandidate(
                action: .deleteArtifact, path: artifact.path, kind: artifact.kind,
                bytes: artifact.totals.bytes, hardlinkedBytes: artifact.totals.hardlinkedBytes,
                idleDays: idle, workspacePath: artifact.workspacePath,
                mainRepositoryPath: workspace?.mainRepositoryPath, reason: reasons.joined(separator: ", ")
            ))
        }
        return candidates.sorted { $0.bytes > $1.bytes }
    }
}
