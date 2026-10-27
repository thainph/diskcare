import Foundation
import Testing
@testable import DiskCareCore

@Suite struct CleanupTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func daysAgo(_ days: Int) -> Date { now.addingTimeInterval(-Double(days) * 86_400) }

    private func totals(_ bytes: Int64) -> Totals {
        var totals = Totals()
        totals.bytes = bytes
        return totals
    }

    private func workspace(_ path: String, kind: WorkspaceKind = .repository, idle: Int, dirty: Int = 0, merged: String? = nil, sourceChange: Int = 0) -> WorkspaceEntry {
        WorkspaceEntry(
            path: path, kind: kind, mainRepositoryPath: kind == .worktree ? "/repo" : nil,
            totals: totals(500_000_000), artifactBytes: 400_000_000, artifactCount: 1,
            lastSourceChangeAt: daysAgo(sourceChange),
            git: GitInfo(branch: "feature", lastCommitAt: daysAgo(idle), lastHeadMoveAt: daysAgo(idle),
                         uncommittedChanges: dirty, mergedInto: merged)
        )
    }

    private func artifact(_path path: String, kind: ArtifactKind, workspace: String?, bytes: Int64 = 400_000_000) -> ArtifactEntry {
        ArtifactEntry(path: path, kind: kind, totals: totals(bytes), workspacePath: workspace, projectLastChangeAt: daysAgo(90))
    }

    private func report(workspaces: [WorkspaceEntry], artifacts: [ArtifactEntry]) -> ScanReport {
        ScanReport(roots: ["/w"], scannedAt: now, stats: ScanStats(), gitDurationSeconds: 0, artifacts: artifacts, workspaces: workspaces)
    }

    @Test func cleanWorkspaceIgnoresNoisyFileMtimes() {
        // Source files touched today, but last commit/checkout 40 days ago and tree is clean.
        let ws = workspace("/w/a", idle: 40)
        #expect(ws.idleDays(now: now) == 40)
        // Dirty tree: recent file changes count as activity.
        #expect(workspace("/w/b", idle: 40, dirty: 2).idleDays(now: now) == 0)
    }

    @Test func plansOnlyIdleCleanWorkspacesByDefault() {
        let report = report(
            workspaces: [workspace("/w/old", idle: 60), workspace("/w/new", idle: 3), workspace("/w/dirty", idle: 90, dirty: 1, sourceChange: 90)],
            artifacts: [
                artifact(_path: "/w/old/node_modules", kind: .nodeModules, workspace: "/w/old"),
                artifact(_path: "/w/new/node_modules", kind: .nodeModules, workspace: "/w/new"),
                artifact(_path: "/w/dirty/.terraform", kind: .terraform, workspace: "/w/dirty"),
                artifact(_path: "/w/loose/target", kind: .cargoTarget, workspace: nil),
            ]
        )
        let plan = CleanupPlanner.plan(report, criteria: CleanupCriteria(minimumIdleDays: 30), now: now)
        #expect(Set(plan.map(\.path)) == ["/w/old/node_modules", "/w/loose/target"])

        let withDirty = CleanupPlanner.plan(report, criteria: CleanupCriteria(minimumIdleDays: 30, includeDirty: true), now: now)
        #expect(withDirty.contains { $0.path == "/w/dirty/.terraform" })

        let terraformOnly = CleanupPlanner.plan(report, criteria: CleanupCriteria(kinds: [.terraform], minimumIdleDays: 30, includeDirty: true), now: now)
        #expect(terraformOnly.map(\.path) == ["/w/dirty/.terraform"])
    }

    @Test func mergedWorktreeIsRemovedInsteadOfItsArtifacts() {
        let report = report(
            workspaces: [
                workspace("/w/wt/done", kind: .worktree, idle: 20, merged: "origin/develop"),
                workspace("/w/wt/open", kind: .worktree, idle: 20),
            ],
            artifacts: [
                artifact(_path: "/w/wt/done/.terraform", kind: .terraform, workspace: "/w/wt/done"),
                artifact(_path: "/w/wt/open/.terraform", kind: .terraform, workspace: "/w/wt/open"),
            ]
        )
        let criteria = CleanupCriteria(minimumIdleDays: 14, removeMergedWorktrees: true)
        let plan = CleanupPlanner.plan(report, criteria: criteria, now: now)
        #expect(plan.count == 2)
        #expect(plan.contains { $0.action == .removeWorktree && $0.path == "/w/wt/done" })
        #expect(plan.contains { $0.action == .deleteArtifact && $0.path == "/w/wt/open/.terraform" })

        let mergedOnly = CleanupPlanner.plan(report, criteria: CleanupCriteria(minimumIdleDays: 14, mergedOnly: true), now: now)
        #expect(mergedOnly.map(\.path) == ["/w/wt/done/.terraform"])
    }

    @Test func cleanerDeletesOnlyValidatedPathsInsideRoots() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diskcare-clean-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let modules = root + "/app/node_modules/pkg"
        try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: URL(fileURLWithPath: modules + "/index.js"))
        let normalizedRoot = ScanOptions.normalize(root)

        let target = CleanupCandidate(
            action: .deleteArtifact, path: normalizedRoot + "/app/node_modules", kind: .nodeModules,
            bytes: 10_000, hardlinkedBytes: 0, idleDays: 40, workspacePath: nil, mainRepositoryPath: nil, reason: "test"
        )
        let outside = CleanupCandidate(
            action: .deleteArtifact, path: "/tmp/not-a-root/node_modules", kind: .nodeModules,
            bytes: 1, hardlinkedBytes: 0, idleDays: 40, workspacePath: nil, mainRepositoryPath: nil, reason: "test"
        )
        let outcomes = Cleaner.execute([target, outside], roots: [normalizedRoot], mode: .delete)

        #expect(outcomes.first { $0.candidate.path == target.path }?.succeeded == true)
        #expect(outcomes.first { $0.candidate.path == outside.path }?.error == "outside scan roots")
        #expect(!FileManager.default.fileExists(atPath: target.path))
        // No staging directory left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: normalizedRoot + "/app").isEmpty)
    }

    @Test func vendoredBuildDirectoriesAreNotArtifacts() {
        #expect(ArtifactRules.classify(directoryName: "build", parentMarkers: .gradleBuild, vendored: true) == nil)
        #expect(ArtifactRules.classify(directoryName: "node_modules", parentMarkers: [], vendored: true) == .nodeModules)
        #expect(ArtifactRules.isVendored("/x/android/third_party/OpenCV/sdk/"))
    }
}
