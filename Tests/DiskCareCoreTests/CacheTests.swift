import Foundation
import Testing
@testable import DiskCareCore

@Suite struct CacheTests {
    private let fm = FileManager.default

    /// Fresh temporary "home" directory (symlinks resolved so paths compare equal after normalization).
    private func makeHome() throws -> String {
        let path = fm.temporaryDirectory.appendingPathComponent("diskcare-cache-tests-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return ScanOptions.normalize(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    private func write(_ path: String, bytes: Int = 1_000, modified: Date? = nil) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
        if let modified { try touch(path, modified) }
    }

    private func touch(_ path: String, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: path)
    }

    private func executable(_ path: String, _ script: String) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + script + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private func scan(_ definitions: [CacheDefinition], home: String, resolver: CommandResolver = CommandResolver(searchPaths: []), now: Date = Date()) -> CacheReport {
        CacheScanner.scan(CacheScanner.Options(definitions: definitions, home: home, resolver: resolver, now: now, workerCount: 2))
    }

    private func daysAgo(_ days: Double) -> Date { Date().addingTimeInterval(-days * 86_400) }

    // MARK: Catalog & paths

    @Test func expandsTildeAndGlobsToExistingDirectories() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: home + "/Library/Developer/Xcode/iOS DeviceSupport", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Library/Developer/Xcode/watchOS DeviceSupport", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/Library/Developer/Xcode/DerivedData", withIntermediateDirectories: true)
        try write(home + "/Library/Developer/Xcode/FakeDeviceSupport")  // a file, not a directory
        try fm.createDirectory(atPath: home + "/real", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.npm", withDestinationPath: home + "/real")

        #expect(CachePaths.expand("~/Library/Developer/Xcode/*DeviceSupport", home: home) == [
            home + "/Library/Developer/Xcode/iOS DeviceSupport",
            home + "/Library/Developer/Xcode/watchOS DeviceSupport",
        ])
        #expect(CachePaths.expand("~/Library/Developer/Xcode/DerivedData/", home: home) == [home + "/Library/Developer/Xcode/DerivedData"])
        #expect(CachePaths.expand("~/missing", home: home).isEmpty)
        #expect(CachePaths.expand("~/.npm", home: home).isEmpty, "symlinked cache roots are skipped")
        #expect(CachePaths.expand("relative/path", home: home).isEmpty)
    }

    @Test func catalogIdsAreUniqueAndModelsAreUserData() {
        let definitions = CacheCatalog.definitions(environment: [:])
        #expect(Set(definitions.map(\.id)).count == definitions.count)
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        for id in ["ollama", "huggingface", "xcode-archives"] {
            #expect(byID[id]?.safety == .userData, "\(id)")
        }
        #expect(!definitions.contains { $0.paths.contains { $0.contains("docker") || $0.contains("orbstack") } })
        #expect(byID["go-mod"]?.paths == ["~/go/pkg/mod"])
        #expect(CacheCatalog.definitions(environment: ["GOPATH": "/opt/gopath:/other"]).first { $0.id == "go-mod" }?.paths == ["/opt/gopath/pkg/mod"])
    }

    @Test func nestedLocationsAreCountedOnce() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/Library/Caches/Homebrew/bottle.tar.gz", bytes: 40_000)
        try write(home + "/Library/Caches/SomeApp/data", bytes: 8_000)
        let report = scan([
            CacheDefinition(id: "homebrew", title: "Homebrew", category: .packageManager, safety: .safe, paths: ["~/Library/Caches/Homebrew"]),
            CacheDefinition(id: "other", title: "Other", category: .system, safety: .safe, paths: ["~/Library/Caches"], fallback: .none),
        ], home: home)
        let homebrew = try #require(report.entry(id: "homebrew"))
        let other = try #require(report.entry(id: "other"))
        #expect(homebrew.bytes >= 40_000 && homebrew.bytes < 48_000)
        #expect(other.bytes >= 8_000 && other.bytes < 40_000)
        #expect(other.method == .reportOnly && !other.isCleanable)
    }

    // MARK: Safety

    @Test func userDataIsNeverSelectedOrCleaned() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/.ollama/models/blobs/sha256-1", bytes: 50_000)
        try write(home + "/.cache/uv/wheel", bytes: 5_000)
        let models = CacheDefinition(id: "ollama", title: "Ollama", category: .aiModels, safety: .userData, paths: ["~/.ollama/models"])
        let uv = CacheDefinition(id: "uv", title: "uv", category: .packageManager, safety: .safe, paths: ["~/.cache/uv"])
        let report = scan([models, uv], home: home)

        #expect(report.entry(id: "ollama")?.method == .reportOnly)
        #expect(report.allSafeIDs == ["uv"])
        #expect(throws: CacheCleanError.self) { try CacheCleaner.targets(ids: ["ollama"], in: report) }

        // Even a hand-built target is refused at clean time.
        let forged = CacheCleanTarget(
            id: "ollama", kind: .entry, title: "Ollama", safety: .userData, paths: [home + "/.ollama/models"],
            containers: [home + "/.ollama/models"], bytes: 0, nativeCommand: nil, fallback: .deleteContents
        )
        let result = CacheCleaner.clean([forged], resolver: CommandResolver(searchPaths: []), home: home)
        #expect(result.outcomes.first?.succeeded == false)
        #expect(fm.fileExists(atPath: home + "/.ollama/models/blobs/sha256-1"))
    }

    @Test func refusesToEmptyBroadDirectories() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: home + "/Library/Caches", withIntermediateDirectories: true)
        #expect(CacheCleaner.checkCacheRoot(home, home: home) != nil)
        #expect(CacheCleaner.checkCacheRoot(home + "/Library/Caches", home: home) != nil)
        #expect(CacheCleaner.checkCacheRoot("/tmp", home: home) != nil)
        try fm.createDirectory(atPath: home + "/Library/Caches/pip", withIntermediateDirectories: true)
        #expect(CacheCleaner.checkCacheRoot(home + "/Library/Caches/pip", home: home) == nil)
    }

    // MARK: Items

    @Test func playwrightKeepsNewestRevisionPerBrowser() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let root = home + "/Library/Caches/ms-playwright"
        let old = daysAgo(120)
        for (name, modified) in [
            ("chromium-1228", old), ("chromium-1243", old), ("chromium-1100", old),
            ("chromium_headless_shell-1228", old), ("chromium_headless_shell-1243", old),
            ("firefox-1400", old), ("ffmpeg-1011", old), ("webkit-2000", daysAgo(3)), ("webkit-1900", daysAgo(3)),
        ] {
            try write("\(root)/\(name)/INSTALLATION_COMPLETE", bytes: 10_000, modified: modified)
            try touch("\(root)/\(name)", modified)
        }
        try write(root + "/b/browser@abc/state", bytes: 100)
        try write(root + "/.links/xyz", bytes: 10)

        let definition = try #require(CacheCatalog.definitions().first { $0.id == "playwright" })
        let report = scan([definition], home: home)
        let entry = try #require(report.entry(id: "playwright"))
        let recommended = Set(entry.recommendedItems.map(\.name))
        #expect(recommended == ["chromium-1228", "chromium-1100", "chromium_headless_shell-1228"])
        // An old revision used recently is flagged but not suggested.
        let webkit = try #require(entry.items.first { $0.name == "webkit-1900" })
        #expect(!webkit.isRecommended && webkit.reason?.contains("used") == true)
        #expect(entry.items.contains { $0.name == "b" && !$0.isRecommended })
        #expect(!entry.items.contains { $0.name.hasPrefix(".") })
        #expect(entry.items.first { $0.name == "chromium-1228" }?.id == "playwright/chromium-1228")
        #expect(Set(report.allSafeIDs) == Set(entry.recommendedItems.map(\.id)))

        // Cleaning one item deletes only that directory.
        let targets = try CacheCleaner.targets(ids: ["playwright/chromium-1228"], in: report)
        let result = CacheCleaner.clean(targets, resolver: CommandResolver(searchPaths: []), home: home)
        #expect(result.outcomes.allSatisfy { $0.succeeded })
        #expect(!fm.fileExists(atPath: root + "/chromium-1228"))
        #expect(fm.fileExists(atPath: root + "/chromium-1243/INSTALLATION_COMPLETE"))
    }

    @Test func itemOutsideItsCacheIsRefused() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/project/keep.txt")
        try fm.createDirectory(atPath: home + "/cache", withIntermediateDirectories: true)
        let forged = CacheCleanTarget(
            id: "cache/../project", kind: .item, title: "x", safety: .safe, paths: [home + "/project"],
            containers: [home + "/cache"], bytes: 0, nativeCommand: nil, fallback: .deleteContents
        )
        let result = CacheCleaner.clean([forged], resolver: CommandResolver(searchPaths: []), home: home)
        #expect(result.outcomes.first?.succeeded == false)
        #expect(fm.fileExists(atPath: home + "/project/keep.txt"))
    }

    @Test func selectingAnEntryDropsItsItems() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/Library/Caches/ms-playwright/chromium-1/x", modified: daysAgo(100))
        try write(home + "/Library/Caches/ms-playwright/chromium-2/x", modified: daysAgo(100))
        let definition = try #require(CacheCatalog.definitions().first { $0.id == "playwright" })
        let report = scan([definition], home: home)
        let targets = try CacheCleaner.targets(ids: ["playwright/chromium-1", "playwright"], in: report)
        #expect(targets.map(\.id) == ["playwright"])
    }

    @Test func versionNumbersParseCommonLayouts() {
        #expect(VersionNumber("chromium-1228").parts == [1228])
        #expect(VersionNumber("mac_arm-148.0.7778.97").parts == [148, 0, 7778, 97])
        #expect(VersionNumber("iPhone15,2 17.0.1 (21A340)").parts == [17, 0, 1])
        #expect(VersionNumber("v22.18.0") > VersionNumber("v22.9.0"))
        #expect(VersionNumber("17.2 (21C62)") > VersionNumber("17.0.1 (21A340)"))
        #expect(VersionNumber("b").parts.isEmpty)
    }

    // MARK: Cleaning

    @Test func fallbackDeletionKeepsTopLevelDirectory() throws {
        let home = try makeHome()
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+w", home]).waitUntilExit()
            try? fm.removeItem(atPath: home)
        }
        let cache = home + "/.cargo/registry"
        try write(cache + "/index/a", bytes: 5_000)
        try write(cache + "/cache/crate.crate", bytes: 5_000)
        try write(cache + "/.hidden", bytes: 10)
        // Read-only tree, like the Go module cache.
        try write(cache + "/src/pkg/lib.rs", bytes: 5_000)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: cache + "/src/pkg")
        // A symlink to data outside the cache: only the link goes away.
        try write(home + "/precious/data.txt")
        try fm.createSymbolicLink(atPath: cache + "/link", withDestinationPath: home + "/precious")

        let definition = CacheDefinition(id: "cargo", title: "Cargo", category: .packageManager, safety: .safe, paths: ["~/.cargo/registry"])
        let report = scan([definition], home: home)
        #expect(report.entry(id: "cargo")?.method == .deleteContents)
        let result = CacheCleaner.clean(try CacheCleaner.targets(ids: ["cargo"], in: report), resolver: CommandResolver(searchPaths: []), home: home)

        let outcome = try #require(result.outcomes.first)
        #expect(outcome.succeeded, "\(outcome.error ?? "")")
        #expect(outcome.action == "delete contents")
        #expect(CachePaths.isRealDirectory(cache))
        #expect(try fm.contentsOfDirectory(atPath: cache).isEmpty)
        #expect(fm.fileExists(atPath: home + "/precious/data.txt"))
    }

    @Test func missingBinaryFallsBackToDeletion() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/bin/plain", bytes: 10)  // not executable
        try executable(home + "/bin/faketool", "exit 0")
        let resolver = CommandResolver(searchPaths: [home + "/nowhere", home + "/bin"])

        #expect(resolver.resolve("faketool") == home + "/bin/faketool")
        #expect(resolver.resolve("plain") == nil)
        #expect(resolver.resolve("definitely-not-installed") == nil)
        #expect(resolver.resolve(NativeCleanCommand(["definitely-not-installed", "faketool"], [])) == home + "/bin/faketool")

        let missing = CacheDefinition(id: "x", title: "x", category: .build, safety: .safe, paths: [],
                                      nativeCommand: NativeCleanCommand(["definitely-not-installed"], ["clean"]))
        #expect(CacheScanner.method(for: missing, resolver: resolver) == .deleteContents)
        var nativeOnly = missing
        nativeOnly.fallback = .none
        #expect(CacheScanner.method(for: nativeOnly, resolver: resolver) == .reportOnly)
        var present = missing
        present.nativeCommand = NativeCleanCommand(["faketool"], [])
        #expect(CacheScanner.method(for: present, resolver: resolver) == .native)

        // End to end: the entry is emptied by the fallback.
        try write(home + "/.cache/tool/blob", bytes: 2_000)
        let definition = CacheDefinition(id: "tool", title: "Tool", category: .build, safety: .safe, paths: ["~/.cache/tool"],
                                         nativeCommand: NativeCleanCommand(["definitely-not-installed"], ["clean"]))
        let report = scan([definition], home: home, resolver: resolver)
        let result = CacheCleaner.clean(try CacheCleaner.targets(ids: ["tool"], in: report), resolver: resolver, home: home)
        #expect(result.outcomes.first?.succeeded == true)
        #expect(result.outcomes.first?.command == nil)
        #expect(!fm.fileExists(atPath: home + "/.cache/tool/blob"))
        #expect(CachePaths.isRealDirectory(home + "/.cache/tool"))
    }

    @Test func runsNativeCommandAndFallsBackWhenItFails() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let marker = home + "/ran"
        try executable(home + "/bin/goodtool", "echo cleaned \"$@\" > '\(marker)'")
        try executable(home + "/bin/badtool", "echo boom >&2; exit 3")
        let resolver = CommandResolver(searchPaths: [home + "/bin"])
        try write(home + "/.cache/good/blob")
        try write(home + "/.cache/bad/blob")
        let report = scan([
            CacheDefinition(id: "good", title: "Good", category: .build, safety: .safe, paths: ["~/.cache/good"],
                            nativeCommand: NativeCleanCommand(["goodtool"], ["cache", "clean"])),
            CacheDefinition(id: "bad", title: "Bad", category: .build, safety: .safe, paths: ["~/.cache/bad"],
                            nativeCommand: NativeCleanCommand(["badtool"], [])),
            CacheDefinition(id: "strict", title: "Strict", category: .build, safety: .regenerable, paths: ["~/.cache/bad"],
                            nativeCommand: NativeCleanCommand(["badtool"], []), fallback: .none),
        ], home: home, resolver: resolver)
        #expect(report.entry(id: "good")?.command == "goodtool cache clean")

        let result = CacheCleaner.clean(try CacheCleaner.targets(ids: ["good", "bad"], in: report), resolver: resolver, home: home)
        let outcomes = Dictionary(uniqueKeysWithValues: result.outcomes.map { ($0.id, $0) })
        #expect(outcomes["good"]?.succeeded == true && outcomes["good"]?.action == "run: goodtool cache clean")
        #expect((try? String(contentsOfFile: marker, encoding: .utf8))?.contains("cleaned cache clean") == true)
        #expect(fm.fileExists(atPath: home + "/.cache/good/blob"), "native command owns the cleanup")

        let bad = try #require(outcomes["bad"])
        #expect(bad.succeeded && bad.command?.exitCode == 3 && bad.command?.output == "boom")
        #expect(!fm.fileExists(atPath: home + "/.cache/bad/blob"))

        // Without a fallback a failing command is reported as a failure.
        let strict = CacheCleanTarget(id: "strict", kind: .entry, title: "Strict", safety: .regenerable, paths: [home + "/.cache/bad"],
                                      containers: [home + "/.cache/bad"], bytes: 0,
                                      nativeCommand: NativeCleanCommand(["badtool"], []), fallback: .none)
        #expect(CacheCleaner.clean([strict], resolver: resolver, home: home).outcomes.first?.succeeded == false)
    }

    @Test func commandTimeoutIsEnforced() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try executable(home + "/slow", "sleep 30")
        let start = Date()
        let result = CommandRunner.run(executable: home + "/slow", arguments: [], timeout: 0.5, searchPaths: [])
        #expect(result.timedOut && !result.succeeded, "\(result)")
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
