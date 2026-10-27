import ArgumentParser
import DiskCareCore
import Foundation

struct Caches: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report and clean global developer caches (package managers, browsers, Xcode…).",
        subcommands: [CachesList.self, CachesClean.self],
        defaultSubcommand: CachesList.self
    )
}

struct CachesList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "Measure known cache locations.")

    @Flag(name: .long, help: "Show every item (browser versions, DerivedData projects…), not only suggested ones.")
    var items = false

    @Flag(name: .long, help: "Print the report as JSON.")
    var json = false

    func run() throws {
        let report = CacheScanner.scan()
        if json {
            try printJSON(report)
            return
        }
        print("Developer caches: \(ByteFormat.string(report.totalBytes)) in \(report.entries.count) locations "
            + "(\(String(format: "%.2f", report.durationSeconds))s); "
            + "safe to clean: \(ByteFormat.string(report.safeReclaimableBytes))")
        var rows: [[String]] = []
        for entry in report.entries {
            rows.append([
                entry.id, entry.title, ByteFormat.string(entry.bytes), entry.safety.label,
                lastUsed(entry.lastModifiedAt), method(entry),
            ])
            let shown = items ? entry.items : entry.items.filter { $0.reason != nil }
            for item in shown {
                rows.append([
                    "  " + item.id, "  ↳ " + (item.reason ?? ""),
                    ByteFormat.string(item.bytes), item.isRecommended ? "suggested" : "",
                    lastUsed(item.lastUsedAt), "delete dir",
                ])
            }
        }
        table(headers: ["ID", "TITLE", "SIZE", "SAFETY", "LAST USED", "METHOD"], rows: rows, rightAligned: [2, 4])
        print("\nClean with: diskcare caches clean <id…> [--apply]   or   diskcare caches clean --all-safe [--apply]")
    }

    private func method(_ entry: CacheEntry) -> String {
        switch entry.method {
        case .native: entry.command ?? "native"
        case .deleteContents: "delete contents"
        case .reportOnly: entry.safety == .userData ? "report only" : "report only (no tool)"
        }
    }
}

struct CachesClean: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Clean caches by id (dry run unless --apply).",
        discussion: """
        --all-safe selects every cache marked `safe` plus suggested items (old browser
        versions, stale DerivedData projects, old device support). User data is never cleaned.

        Examples:
          diskcare caches clean --all-safe                 # preview
          diskcare caches clean homebrew uv npm --apply
          diskcare caches clean playwright/chromium-1228 --apply -y
        """
    )

    @Argument(help: "Cache or item ids (see `diskcare caches`).")
    var ids: [String] = []

    @Flag(name: .long, help: "Select all safe caches and suggested items.")
    var allSafe = false

    @Flag(name: .long, help: "Move to Trash instead of deleting (native commands are skipped where possible).")
    var trash = false

    @Flag(name: .long, help: "Actually clean. Without it, only the plan is printed.")
    var apply = false

    @Flag(name: [.short, .long], help: "Do not ask for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print the plan (and outcomes) as JSON.")
    var json = false

    func validate() throws {
        if ids.isEmpty && !allSafe { throw ValidationError("Pass cache ids or --all-safe.") }
    }

    func run() throws {
        let resolver = CommandResolver.standard()
        let report = CacheScanner.scan(CacheScanner.Options(resolver: resolver))
        let targets: [CacheCleanTarget]
        do {
            targets = try CacheCleaner.targets(ids: (allSafe ? report.allSafeIDs : []) + ids, in: report)
        } catch let error as CacheCleanError {
            throw ValidationError(error.description)
        }
        let mode: CleanupMode = trash ? .trash : .delete

        if json && !apply {
            try printJSON(targets)
            return
        }
        guard !targets.isEmpty else {
            print("Nothing to clean.")
            return
        }
        let total = targets.reduce(Int64(0)) { $0 + $1.bytes }
        print("Cache cleanup plan: \(targets.count) items, \(ByteFormat.string(total))")
        table(
            headers: ["ID", "SIZE", "SAFETY", "ACTION"],
            rows: targets.map { [$0.id, ByteFormat.string($0.bytes), $0.safety.label, $0.action(mode: mode, resolver: resolver)] },
            rightAligned: [1]
        )
        guard apply else {
            print("\nDry run. Re-run with --apply to clean.")
            return
        }
        guard yes || confirm(count: targets.count, bytes: total) else {
            print("Aborted.")
            return
        }

        let result = CacheCleaner.clean(targets, mode: mode, resolver: resolver) { outcome in
            if !json {
                print("  \(outcome.succeeded ? "✓" : "✗") \(outcome.target.id): \(outcome.action)")
            }
        }
        if json {
            try printJSON(result)
            return
        }
        let failed = result.outcomes.filter { !$0.succeeded }
        print("\nCleaned \(result.outcomes.count - failed.count)/\(result.outcomes.count) caches.")
        if let before = result.freeBytesBefore, let after = result.freeBytesAfter {
            print("Free space: \(ByteFormat.string(before)) → \(ByteFormat.string(after))\(trash ? " (empty the Trash to reclaim)" : "")")
        }
        for outcome in failed {
            print("  failed: \(outcome.target.id): \(outcome.error ?? "unknown error")")
        }
        if !failed.isEmpty { throw ExitCode(1) }
    }

    private func confirm(count: Int, bytes: Int64) -> Bool {
        print("\n\(trash ? "Move to Trash" : "Permanently clean") \(count) caches (\(ByteFormat.string(bytes)))? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }
}

private func lastUsed(_ date: Date?) -> String {
    guard let date else { return "-" }
    let days = Int(max(0, Date().timeIntervalSince(date)) / 86_400)
    return days == 0 ? "today" : "\(days)d ago"
}

private extension CacheSafety {
    var label: String {
        switch self {
        case .safe: "safe"
        case .regenerable: "regenerable"
        case .userData: "user data"
        }
    }
}
