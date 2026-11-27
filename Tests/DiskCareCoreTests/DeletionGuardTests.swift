import Foundation
import Testing
@testable import DiskCareCore

@Suite struct DeletionGuardTests {
    private let fm = FileManager.default

    /// Temporary directory as the user would type it (`/var/folders/…`, not `/private/var/…`).
    private func makeRoot() throws -> String {
        let path = fm.temporaryDirectory.appendingPathComponent("diskcare-guard-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return ScanOptions.normalize(path)
    }

    private func mkdir(_ path: String) throws {
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // MARK: Aliases

    @Test func firmlinkAliasOfProtectedLocationsIsRefused() {
        let home = NSHomeDirectory()
        let alias = "/System/Volumes/Data" + home
        guard fm.fileExists(atPath: alias) else { return }
        let guardrail = DeletionGuard(roots: ["/Users"])
        #expect(guardrail.checkRemoval(alias) != nil)
        #expect(guardrail.checkRemoval(alias + "/Library") != nil)
        #expect(guardrail.checkRemoval(alias + "/Library/Caches") != nil)
        #expect(DeletionGuard(roots: []).checkEmptying(alias + "/Library/Caches") != nil)
        #expect(DeletionGuard(roots: []).checkEmptying("/System/Volumes/Data/Users") != nil)
    }

    @Test func rootThroughSymlinkStillAllowsItsContents() throws {
        let base = try makeRoot()
        defer { try? fm.removeItem(atPath: base) }
        try mkdir(base + "/real/app/node_modules")
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/real")

        let guardrail = DeletionGuard(roots: [base + "/link"])
        #expect(guardrail.checkRemoval(base + "/link/app/node_modules") == nil)
        #expect(guardrail.checkRemoval(base + "/real/app/node_modules") == nil)
        // `/var` → `/private/var` on both sides.
        #expect(DeletionGuard(roots: [base]).checkRemoval(base + "/real/app/node_modules") == nil)
        #expect(DeletionGuard(roots: [base]).checkRemoval("/private" + base + "/real/app/node_modules") == nil)
    }

    @Test func letterCaseDifferencesAreTheSameDirectory() throws {
        let base = try makeRoot()
        defer { try? fm.removeItem(atPath: base) }
        try mkdir(base + "/Proj/node_modules")
        guard fm.fileExists(atPath: base + "/PROJ/NODE_MODULES") else { return }  // case-sensitive volume
        let guardrail = DeletionGuard(roots: [base + "/proj"])
        #expect(guardrail.checkRemoval(base + "/PROJ/NODE_MODULES") == nil)
        #expect(guardrail.checkRemoval(base + "/PROJ") != nil, "the root itself, spelled differently")
    }

    // MARK: Roots

    @Test func rootsAndTheirAncestorsAreRefused() throws {
        let base = try makeRoot()
        defer { try? fm.removeItem(atPath: base) }
        try mkdir(base + "/a/b/c")
        let guardrail = DeletionGuard(roots: [base, base + "/a/b"])
        #expect(guardrail.checkRemoval(base + "/a") == "refusing to delete a scan root or its parent")
        #expect(guardrail.checkRemoval(base + "/a/b") != nil)
        #expect(guardrail.checkRemoval(base) != nil)
        #expect(guardrail.checkRemoval(base + "/a/b/c") == nil)
    }

    @Test func symlinksAndEscapesAreRefused() throws {
        let base = try makeRoot()
        let outside = try makeRoot()
        defer {
            try? fm.removeItem(atPath: base)
            try? fm.removeItem(atPath: outside)
        }
        try mkdir(base + "/root/proj")
        try mkdir(outside + "/node_modules")
        try fm.createSymbolicLink(atPath: base + "/root/proj/node_modules", withDestinationPath: outside + "/node_modules")
        try fm.createSymbolicLink(atPath: base + "/root/proj/escape", withDestinationPath: outside)

        let guardrail = DeletionGuard(roots: [base + "/root"])
        #expect(guardrail.checkRemoval(base + "/root/proj/node_modules") == "not a directory (symlink?)")
        #expect(guardrail.checkRemoval(base + "/root/proj/escape/node_modules") == "outside scan roots")
        #expect(guardrail.checkRemoval(base + "/root/proj/../../root/proj") == nil)
        #expect(guardrail.checkRemoval(base + "/root/proj/missing") == "no longer exists")
        #expect(guardrail.checkRemoval("relative/path") != nil)
    }

    @Test func protectedLocationsOfTheGivenHomeAreRefused() throws {
        let home = try makeRoot()
        defer { try? fm.removeItem(atPath: home) }
        for path in ["/Library/Caches/pip", "/.cargo/registry", "/.config/tool"] { try mkdir(home + path) }
        let guardrail = DeletionGuard(roots: [home], home: home)
        #expect(guardrail.checkRemoval(home + "/Library/Caches") != nil)
        #expect(guardrail.checkRemoval(home + "/Library") != nil)
        #expect(guardrail.checkRemoval(home + "/.cargo") != nil)
        #expect(guardrail.checkRemoval(home + "/.config") != nil)
        #expect(guardrail.checkRemoval(home + "/Library/Caches/pip") == nil)
        #expect(guardrail.checkRemoval(home + "/.cargo/registry") == nil)

        let emptying = DeletionGuard(roots: [], home: home)
        #expect(emptying.checkEmptying(home + "/.cargo") != nil)
        #expect(emptying.checkEmptying(home + "/.cargo/registry") == nil)
        #expect(emptying.checkEmptying("/private/tmp") != nil)
        let cargoHome = DeletionGuard(roots: [], home: home, environment: ["CARGO_HOME": home + "/.config/tool"])
        #expect(cargoHome.checkEmptying(home + "/.config/tool") != nil)
    }

    // MARK: Interrupted deletes

    @Test func failedDeleteReportsItsStagingDirectory() throws {
        let base = try makeRoot()
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", base]).waitUntilExit()
            try? fm.removeItem(atPath: base)
        }
        try mkdir(base + "/proj/node_modules/locked")
        try Data(count: 10).write(to: URL(fileURLWithPath: base + "/proj/node_modules/locked/file"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: base + "/proj/node_modules/locked")

        #expect {
            try Cleaner.removeTree(base + "/proj/node_modules")
        } throws: { error in
            guard case CleanupError.partiallyRemoved(let staging, _) = error else { return false }
            return (staging as NSString).lastPathComponent.hasPrefix(Cleaner.stagingPrefix) && fm.fileExists(atPath: staging)
        }
        #expect(!fm.fileExists(atPath: base + "/proj/node_modules"))
    }

    @Test func leftoverStagingIsPlannedRegardlessOfActivity() {
        #expect(ArtifactRules.classify(directoryName: Cleaner.stagingPrefix + "ABC", parentMarkers: []) == .cleanupLeftover)
        #expect(ArtifactRules.classify(directoryName: Cleaner.stagingPrefix + "ABC", parentMarkers: [], vendored: true) == .cleanupLeftover)
        var totals = Totals()
        totals.bytes = 5_000_000
        let now = Date()
        let report = ScanReport(
            roots: ["/w"], scannedAt: now, stats: ScanStats(), gitDurationSeconds: 0,
            artifacts: [
                ArtifactEntry(path: "/w/app/" + Cleaner.stagingPrefix + "X", kind: .cleanupLeftover, totals: totals, workspacePath: nil, projectLastChangeAt: now),
                ArtifactEntry(path: "/w/app/node_modules", kind: .nodeModules, totals: totals, workspacePath: nil, projectLastChangeAt: now),
            ],
            workspaces: []
        )
        let plan = CleanupPlanner.plan(report, criteria: CleanupCriteria(minimumIdleDays: 30), now: now)
        #expect(plan.map(\.kind) == [.cleanupLeftover])
    }
}

@Suite struct CacheSelectionTests {
    private let fm = FileManager.default

    private func item(_ name: String, recommended: Bool = true, preselectable: Bool = true, bytes: Int64 = 100) -> CacheItem {
        CacheItem(
            id: "tool/" + name, entryID: "tool", name: name, path: "/c/tool/" + name, bytes: bytes, hardlinkedBytes: 0,
            lastUsedAt: nil, isRecommended: recommended, isPreselectable: preselectable, reason: "test"
        )
    }

    private func report(_ items: [CacheItem]) -> CacheReport {
        let entry = CacheEntry(
            id: "tool", title: "Tool", category: .build, safety: .regenerable, paths: ["/c/tool"], bytes: 1_000,
            hardlinkedBytes: 0, files: 1, lastModifiedAt: nil, method: .deleteContents, command: nil, nativeCommand: nil,
            fallback: .deleteContents, note: nil, items: items
        )
        return CacheReport(scannedAt: Date(), durationSeconds: 0, entries: [entry])
    }

    @Test func nestedSelectionsAreMergedAndCountedOnce() throws {
        let report = report([item("debug", bytes: 300), item("debug/incremental", bytes: 200), item("release", bytes: 50)])
        let targets = try CacheCleaner.targets(ids: ["tool/debug/incremental", "tool/debug", "tool/release"], in: report)
        #expect(Set(targets.map(\.id)) == ["tool/debug", "tool/release"])
        #expect(report.safeReclaimableBytes == 350)
        #expect(Set(report.allSafeIDs) == ["tool/debug", "tool/release"])
        // A sibling whose name only shares a prefix is not nested.
        let siblings = self.report([item("debug"), item("debug-old")])
        let siblingTargets = try CacheCleaner.targets(ids: ["tool/debug", "tool/debug-old"], in: siblings)
        #expect(siblingTargets.count == 2)
    }

    @Test func onlyPreselectableItemsAreSelectedByDefault() {
        let report = report([item("incremental"), item("bundle", preselectable: false), item("fresh", recommended: false)])
        #expect(report.allSafeIDs == ["tool/incremental"])
        #expect(report.entries[0].items.first { $0.name == "fresh" }?.isPreselectable == false, "never preselect what is not recommended")
    }

    @Test func savedReportsWithoutPreselectableStillDecode() throws {
        let json = #"{"id":"tool/a","entryID":"tool","name":"a","path":"/c/tool/a","bytes":1,"hardlinkedBytes":0,"isRecommended":true,"reason":"old"}"#
        let decoded = try JSONDecoder().decode(CacheItem.self, from: Data(json.utf8))
        #expect(decoded.isRecommended && !decoded.isPreselectable)
    }

    @Test func leftoverInsideCacheIsListedAndFinished() throws {
        let home = ScanOptions.normalize(URL(fileURLWithPath: fm.temporaryDirectory.appendingPathComponent("diskcare-leftover-\(UUID().uuidString)").path).resolvingSymlinksInPath().path)
        defer { try? fm.removeItem(atPath: home) }
        let cache = home + "/.cache/tool"
        let staging = cache + "/" + Cleaner.stagingPrefix + "ABC"
        try fm.createDirectory(atPath: staging + "/deep", withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: URL(fileURLWithPath: staging + "/deep/blob"))
        try Data(count: 10).write(to: URL(fileURLWithPath: cache + "/keep"))

        let definition = CacheDefinition(id: "tool", title: "Tool", category: .build, safety: .regenerable, paths: ["~/.cache/tool"])
        let report = CacheScanner.scan(CacheScanner.Options(definitions: [definition], home: home, resolver: CommandResolver(searchPaths: []), workerCount: 2))
        let leftover = try #require(report.entry(id: "tool")?.items.first)
        #expect(leftover.isRecommended && leftover.isPreselectable && leftover.path == staging)
        #expect(report.allSafeIDs == [leftover.id])

        let result = CacheCleaner.clean(try CacheCleaner.targets(ids: report.allSafeIDs, in: report), resolver: CommandResolver(searchPaths: []), home: home)
        #expect(result.outcomes.allSatisfy { $0.succeeded })
        #expect(!fm.fileExists(atPath: staging))
        #expect(fm.fileExists(atPath: cache + "/keep"))
        let records = DeletionLog(path: home + "/Library/Application Support/DiskCare/deletions.jsonl").records()
        #expect(records.map(\.source) == ["cache-item"] && records.first?.path == staging)
    }
}
