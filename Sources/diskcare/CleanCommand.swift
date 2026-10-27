import ArgumentParser
import DiskCareCore
import Foundation

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete regenerable artifacts of idle projects (dry run unless --apply).",
        discussion: """
        Examples:
          diskcare clean ~/Workspace                         # preview what would be cleaned
          diskcare clean ~/Workspace --kind .terraform --idle-days 7 --apply
          diskcare clean ~/Workspace --remove-merged-worktrees --apply
        """
    )

    @OptionGroup var scan: ScanArguments

    @Option(name: .long, help: "Only these artifact kinds (repeatable): \(ArtifactKind.allCases.filter(\.isRegenerable).map(\.rawValue).joined(separator: ", ")).")
    var kind: [String] = []

    @Option(name: .long, help: "Minimum days since last activity of the owning workspace/project.")
    var idleDays: Int = 30

    @Option(name: .long, help: "Skip artifacts smaller than this.")
    var minSize: String = "10MB"

    @Flag(name: .long, help: "Also clean workspaces with uncommitted changes.")
    var includeDirty = false

    @Flag(name: .long, help: "Only clean workspaces already merged into main/master/develop.")
    var mergedOnly = false

    @Flag(name: .long, help: "Remove whole linked worktrees that are clean, merged and idle (branch is kept).")
    var removeMergedWorktrees = false

    @Flag(name: .long, help: "Move to Trash instead of deleting (space is freed only when Trash is emptied).")
    var trash = false

    @Flag(name: .long, help: "Actually clean. Without it, only the plan is printed.")
    var apply = false

    @Flag(name: [.short, .long], help: "Do not ask for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print the plan (and outcomes) as JSON.")
    var json = false

    func run() throws {
        let kinds = try kind.isEmpty ? nil : Set(kind.map { name in
            guard let kind = ArtifactKind(rawValue: name), kind.isRegenerable else {
                throw ValidationError("Unknown or non-regenerable kind: \(name)")
            }
            return kind
        })
        let criteria = CleanupCriteria(
            kinds: kinds, minimumIdleDays: idleDays, minimumBytes: try parseSize(minSize),
            includeDirty: includeDirty, mergedOnly: mergedOnly, removeMergedWorktrees: removeMergedWorktrees
        )

        let options = scan.options
        let report = DiskAnalyzer.analyze(options)
        let plan = CleanupPlanner.plan(report, criteria: criteria)

        if json && !apply {
            try printJSON(plan)
            return
        }
        printPlan(plan)
        guard apply, !plan.isEmpty else {
            if !plan.isEmpty { print("\nDry run. Re-run with --apply to clean.") }
            return
        }
        guard yes || confirm(plan) else {
            print("Aborted.")
            return
        }

        let volume = options.roots.first ?? NSHomeDirectory()
        let freeBefore = Cleaner.availableCapacity(at: volume)
        let outcomes = Cleaner.execute(plan, roots: options.roots, mode: trash ? .trash : .delete)
        let freeAfter = Cleaner.availableCapacity(at: volume)

        if json {
            try printJSON(outcomes)
            return
        }
        let failed = outcomes.filter { !$0.succeeded }
        let cleaned = outcomes.filter(\.succeeded).reduce(Int64(0)) { $0 + $1.candidate.bytes }
        print("\nCleaned \(outcomes.count - failed.count)/\(outcomes.count) items, ~\(ByteFormat.string(cleaned)).")
        if let freeBefore, let freeAfter {
            print("Free space: \(ByteFormat.string(freeBefore)) → \(ByteFormat.string(freeAfter))\(trash ? " (empty the Trash to reclaim)" : "")")
        }
        for outcome in failed {
            print("  failed: \(outcome.candidate.path.abbreviatingHome): \(outcome.error ?? "unknown error")")
        }
        if !failed.isEmpty { throw ExitCode(1) }
    }

    private func printPlan(_ plan: [CleanupCandidate]) {
        guard !plan.isEmpty else {
            print("Nothing to clean with the current criteria (idle ≥ \(idleDays)d).")
            return
        }
        let total = plan.reduce(Int64(0)) { $0 + $1.bytes }
        let linked = plan.reduce(Int64(0)) { $0 + $1.hardlinkedBytes }
        print("Cleanup plan: \(plan.count) items, \(ByteFormat.string(total))"
            + (linked > 0 ? " (incl. \(ByteFormat.string(linked)) hard-linked, may not be freed)" : ""))
        TablePrinter.print(
            headers: ["SIZE", "ACTION", "KIND", "WHY", "PATH"],
            rows: plan.map {
                [
                    ByteFormat.string($0.bytes),
                    $0.action == .removeWorktree ? "rm worktree" : (trash ? "trash" : "delete"),
                    $0.kind?.rawValue ?? "-",
                    $0.reason,
                    $0.path.abbreviatingHome,
                ]
            },
            rightAligned: [0]
        )
    }

    private func confirm(_ plan: [CleanupCandidate]) -> Bool {
        let total = plan.reduce(Int64(0)) { $0 + $1.bytes }
        print("\n\(trash ? "Move to Trash" : "Permanently delete") \(plan.count) items (\(ByteFormat.string(total)))? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }
}
