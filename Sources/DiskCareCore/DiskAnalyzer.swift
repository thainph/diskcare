import Foundation

/// Entry point: scans the filesystem, then enriches workspaces with git state.
public enum DiskAnalyzer {
    public static func analyze(_ options: ScanOptions, inspectGit: Bool = true) -> ScanReport {
        let tree = FileSystemScanner.scan(options)
        return report(from: tree, inspectGit: inspectGit, priority: options.priority, progress: options.progress)
    }

    public static func analyze(_ options: ScanOptions, inspectGit: Bool = true) async -> ScanReport {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                options.priority.applyToCurrentThread()
                continuation.resume(returning: analyze(options, inspectGit: inspectGit))
            }
        }
    }

    static func report(from tree: ScanTree, inspectGit: Bool, priority: ScanPriority = .userInitiated, progress: ScanProgress? = nil) -> ScanReport {
        let nodes = tree.nodes
        // Nearest enclosing workspace for every node; parents come first, so one forward pass suffices.
        var workspaceOf = [Int32](repeating: -1, count: nodes.count)
        for node in nodes {
            let inherited = node.parent >= 0 ? workspaceOf[Int(node.parent)] : -1
            workspaceOf[Int(node.id)] = isWorkspace(node) ? node.id : inherited
        }

        var artifacts: [ArtifactEntry] = []
        var artifactBytes: [Int32: Int64] = [:]
        var artifactCount: [Int32: Int] = [:]
        for node in nodes {
            guard let kind = node.artifact, kind.isRegenerable, node.total.bytes > 0 else { continue }
            let workspace = workspaceOf[Int(node.id)]
            let owner = node.parent >= 0 ? nodes[Int(node.parent)].latestSourceModification : 0
            artifacts.append(ArtifactEntry(
                path: node.path, kind: kind, totals: node.total,
                workspacePath: workspace >= 0 ? nodes[Int(workspace)].path : nil,
                projectLastChangeAt: owner > 0 ? Date(timeIntervalSince1970: TimeInterval(owner)) : nil
            ))
            // Credit the artifact to every enclosing workspace (nested repos included).
            var current = workspace
            while current >= 0 {
                artifactBytes[current, default: 0] += node.total.bytes
                artifactCount[current, default: 0] += 1
                let parent = nodes[Int(current)].parent
                current = parent >= 0 ? workspaceOf[Int(parent)] : -1
            }
        }

        var workspaces: [WorkspaceEntry] = nodes.compactMap { node in
            guard isWorkspace(node) else { return nil }
            let isWorktree = node.markers.contains(.gitFile) && !node.markers.contains(.gitDirectory)
            return WorkspaceEntry(
                path: node.path,
                kind: isWorktree ? .worktree : .repository,
                mainRepositoryPath: isWorktree ? GitInspector.mainRepository(ofWorktree: node.path) : nil,
                totals: node.total,
                artifactBytes: artifactBytes[node.id] ?? 0,
                artifactCount: artifactCount[node.id] ?? 0,
                lastSourceChangeAt: node.latestSourceModification > 0
                    ? Date(timeIntervalSince1970: TimeInterval(node.latestSourceModification)) : nil
            )
        }

        let gitClock = ContinuousClock.now
        if inspectGit {
            let infos = GitInspector.inspect(workspaces.map(\.path), priority: priority, progress: progress)
            for index in workspaces.indices { workspaces[index].git = infos[index] }
        }
        let gitDuration = (ContinuousClock.now - gitClock).seconds

        return ScanReport(
            roots: tree.roots,
            scannedAt: Date(),
            stats: tree.stats,
            gitDurationSeconds: gitDuration,
            artifacts: artifacts.sorted { $0.totals.bytes > $1.totals.bytes },
            workspaces: workspaces.sorted { $0.artifactBytes > $1.artifactBytes }
        )
    }

    private static func isWorkspace(_ node: DirectoryNode) -> Bool {
        node.artifact == nil && !node.markers.isDisjoint(with: .anyGit)
    }
}
