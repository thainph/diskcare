import Darwin
import Foundation
import Testing
@testable import DiskCareCore

@Suite struct CargoBuildTests {
    private let fm = FileManager.default
    private static let tag = CargoBuildDirectory.cacheDirTagSignature + "\n# This file is a cache directory tag created by cargo.\n"

    /// Fresh fake home with symlinks resolved, so paths compare equal after normalization.
    private func makeHome() throws -> String {
        let path = fm.temporaryDirectory.appendingPathComponent("diskcare-cargo-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return ScanOptions.normalize(URL(fileURLWithPath: path).resolvingSymlinksInPath().path)
    }

    private func write(_ path: String, _ text: String = "x", bytes: Int? = nil) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let bytes {
            try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
        } else {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// A target dir the way Cargo lays it out (debug + release + one cross target).
    private func makeTargetDir(_ path: String) throws {
        try write(path + "/CACHEDIR.TAG", Self.tag)
        try write(path + "/.rustc_info.json", "{}")
        for profile in ["debug", "release", "aarch64-apple-darwin/debug"] {
            try write("\(path)/\(profile)/.cargo-lock", "")
            try write("\(path)/\(profile)/.fingerprint/app-1/lib", bytes: 100)
            try write("\(path)/\(profile)/deps/libapp-1.rlib", bytes: 20_000)
            try write("\(path)/\(profile)/incremental/app-1/s-1/dep-graph.bin", bytes: 30_000)
        }
        try write(path + "/release/bundle/macos/App.app/Contents/MacOS/App", bytes: 5_000)
    }

    private func scan(_ definitions: [CacheDefinition], home: String, inUse: InUseIndex = .empty) -> CacheReport {
        var options = CacheScanner.Options(definitions: definitions, home: home, resolver: CommandResolver(searchPaths: []), workerCount: 2)
        options.inUse = inUse
        return CacheScanner.scan(options)
    }

    // MARK: Locator

    @Test func locatorFollowsCargoSourcesAndResolvesPaths() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        // CARGO_HOME exported in a shell rc file (GUI apps never see it in their environment).
        try write(home + "/.zshrc", "export CARGO_HOME=\"$HOME/rust/cargo\"\nexport CARGO_TARGET_DIR=/opt/never-created\n")
        try write(home + "/rust/cargo/config", "[build]\ntarget-dir = \"shared\"\n")  // legacy name, relative
        try write(home + "/work/.cargo/config.toml", "build.build-dir = \"{cargo-cache-home}/build/{workspace-path-hash}\"\n")
        try write(home + "/work/app/.cargo/config.toml", "[build]\nbuild-dir = \"{workspace-root}/build\"\n")
        try fm.createDirectory(atPath: home + "/work/app/src", withIntermediateDirectories: true)

        #expect(CargoBuildLocator.cargoHome(home: home, environment: [:]) == home + "/rust/cargo")
        let locations = CargoBuildLocator.locate(home: home, environment: [:], scanRoots: [home + "/work/app"])
        let byPath = Dictionary(uniqueKeysWithValues: locations.map { ($0.path, $0) })
        #expect(byPath["/opt/never-created"]?.source == "CARGO_TARGET_DIR")
        #expect(byPath[home + "/rust/shared"]?.buildDirDepth == 0, "relative to the directory holding .cargo")
        #expect(byPath[home + "/rust/cargo/build"]?.buildDirDepth == 2)
        #expect(!locations.contains { $0.path.contains("{") }, "per-workspace templates are skipped")

        // The environment wins over rc files.
        let fromEnvironment = CargoBuildLocator.cargoHome(home: home, environment: ["CARGO_HOME": "/env/cargo"])
        #expect(fromEnvironment == "/env/cargo")
    }

    @Test func locatorDropsDuplicatesAndNestedDirs() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: home + "/t/inner", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/alias", withDestinationPath: home + "/t")
        let unique = CargoBuildLocator.deduplicated([
            CargoBuildLocation(source: "a", path: home + "/t", buildDirDepth: 0),
            CargoBuildLocation(source: "b", path: home + "/alias", buildDirDepth: 0),
            CargoBuildLocation(source: "c", path: home + "/t/inner", buildDirDepth: 0),
        ])
        #expect(unique.map(\.source) == ["a"])
    }

    @Test func configValuesInEverySpelling() {
        #expect(CargoConfig.value(of: "build.build-dir", in: "[build]\nbuild-dir = \"/b\"") == "/b")
        #expect(CargoConfig.value(of: "build.rustc-wrapper", in: "build = { rustc-wrapper = \"/w\" }") == "/w")
        #expect(CargoConfig.value(of: "build.target-dir", in: "build = { build-dir = \"/x\" }") == nil)
    }

    // MARK: Gate

    @Test func gateRefusesAnythingThatIsNotPlainCargoOutput() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let roots = [home + "/work/proj"]
        try fm.createDirectory(atPath: roots[0], withIntermediateDirectories: true)
        let guardrail = DeletionGuard(roots: roots, home: home, environment: [:])
        func problem(_ path: String) -> String? { CargoBuildDirectory.gateProblem(path, guardrail: guardrail) }

        try makeTargetDir(home + "/ok")
        try write(home + "/ok/" + Cleaner.stagingPrefix + UUID().uuidString + "/x")
        #expect(problem(home + "/ok") == nil)

        #expect(problem(home) != nil, "home")
        #expect(problem(roots[0]) != nil, "scan root")
        #expect(problem(home + "/work") != nil, "ancestor of a scan root")
        try fm.createSymbolicLink(atPath: home + "/link", withDestinationPath: home + "/ok")
        #expect(problem(home + "/link") != nil, "symlink")

        try makeTargetDir(home + "/untagged")
        try fm.removeItem(atPath: home + "/untagged/CACHEDIR.TAG")
        #expect(problem(home + "/untagged") == "no Cargo CACHEDIR.TAG")
        try makeTargetDir(home + "/wrongtag")
        try write(home + "/wrongtag/CACHEDIR.TAG", "Signature: 0000")
        #expect(problem(home + "/wrongtag") == "no Cargo CACHEDIR.TAG")

        for (name, marker) in [("git", ".git/HEAD"), ("manifest", "Cargo.toml"), ("stranger", "notes/todo.txt")] {
            try makeTargetDir(home + "/" + name)
            try write(home + "/" + name + "/" + marker)
            #expect(problem(home + "/" + name) != nil, "\(name)")
        }
    }

    // MARK: Catalog & items

    @Test func sharedTargetDirIsMeasuredButNeverEmptiedWhole() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let target = home + "/.cargo/target-shared"
        try makeTargetDir(target)
        try write(target + "/release/criterion-baseline", bytes: 10)  // a file: fine
        try write(home + "/.cargo/config.toml", "[build]\ntarget-dir = \"\(target)\"\n")

        let definitions = CacheCatalog.cargoBuild(home: home, environment: [:], scanRoots: [])
        let definition = try #require(definitions.first)
        #expect(definition.id == "cargo-target-shared" && definition.fallback == .none && definition.safety == .regenerable)
        let report = scan(definitions, home: home)
        let entry = try #require(report.entry(id: "cargo-target-shared"))
        #expect(entry.method == .reportOnly && !entry.isCleanable)
        #expect(throws: CacheCleanError.self) { try CacheCleaner.targets(ids: ["cargo-target-shared"], in: report) }

        let items = Dictionary(uniqueKeysWithValues: entry.items.map { ($0.name, $0) })
        for profile in ["debug", "release", "aarch64-apple-darwin/debug"] {
            let incremental = try #require(items[profile + "/incremental"], "\(profile)")
            #expect(incremental.isRecommended && incremental.isPreselectable && incremental.lockFile == "\(target)/\(profile)/.cargo-lock")
            let whole = try #require(items[profile])
            #expect(!whole.isRecommended && !whole.isPreselectable && whole.isCleanable)
        }
        #expect(items["release"]?.reason?.contains("bundle") == true)
        #expect(Set(report.allSafeIDs) == Set(["debug", "release", "aarch64-apple-darwin/debug"].map { "cargo-target-shared/\($0)/incremental" }))

        // Whole profile + its incremental selected: one target.
        let targets = try CacheCleaner.targets(ids: ["cargo-target-shared/debug/incremental", "cargo-target-shared/debug"], in: report)
        #expect(targets.map(\.id) == ["cargo-target-shared/debug"])
    }

    @Test func unknownDirectoryInProfileBlocksIt() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let target = home + "/shared"
        try makeTargetDir(target)
        try write(target + "/debug/criterion/base/estimates.json")
        let definition = CacheDefinition(id: "t", title: "t", category: .build, safety: .regenerable, paths: [target],
                                         fallback: .none, itemRule: .cargoProfiles(buildDirDepth: 0))
        let report = scan([definition], home: home)
        let debug = try #require(report.item(id: "t/debug"))
        #expect(debug.blockedReason?.contains("criterion") == true)
        #expect(throws: CacheCleanError.self) { try CacheCleaner.targets(ids: ["t/debug"], in: report) }
        #expect(report.item(id: "t/debug/incremental")?.isCleanable == true)
    }

    @Test func failingGateMakesTheEntryReportOnly() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try fm.createDirectory(atPath: home + "/Documents/rust", withIntermediateDirectories: true)
        try write(home + "/.cargo/config.toml", "[build]\ntarget-dir = \"\(home)/Documents\"\n")
        let definition = try #require(CacheCatalog.cargoBuild(home: home, environment: [:], scanRoots: []).first)
        #expect(definition.safety == .userData && definition.itemRule == nil)
        #expect(definition.note?.hasPrefix("report only") == true)
    }

    @Test func templatedBuildDirsAreCheckedOneByOne() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try makeTargetDir(home + "/.cargo/build/7b/07f560fc88d254")
        try makeTargetDir(home + "/.cargo/build/aa/bbbbbbbbbbbbbb")
        try write(home + "/.cargo/build/aa/bbbbbbbbbbbbbb/Cargo.toml")
        try write(home + "/.cargo/config.toml", "[build]\nbuild-dir = \"{cargo-cache-home}/build/{workspace-path-hash}\"\n")
        let definitions = CacheCatalog.cargoBuild(home: home, environment: [:], scanRoots: [])
        #expect(definitions.map(\.id) == ["cargo-build-dir"])
        let report = scan(definitions, home: home)
        let entry = try #require(report.entry(id: "cargo-build-dir"))
        let good = try #require(entry.items.first { $0.name == "7b/07f560fc88d254/debug/incremental" })
        #expect(good.isPreselectable)
        let bad = try #require(entry.items.first { $0.name == "aa/bbbbbbbbbbbbbb/debug/incremental" })
        #expect(bad.blockedReason?.contains("Cargo.toml") == true)
    }

    // MARK: Lock & in use

    @Test func runningBuildLockSkipsTheItem() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let target = home + "/shared"
        try makeTargetDir(target)
        let definition = CacheDefinition(id: "t", title: "t", category: .build, safety: .regenerable, paths: [target],
                                         fallback: .none, itemRule: .cargoProfiles(buildDirDepth: 0))
        let report = scan([definition], home: home)

        // Cargo holds an exclusive flock on the profile's .cargo-lock while building.
        let held = open(target + "/debug/.cargo-lock", O_RDONLY)
        #expect(flock(held, LOCK_EX | LOCK_NB) == 0)
        let targets = try CacheCleaner.targets(ids: ["t/debug/incremental", "t/release/incremental"], in: report)
        let log = DeletionLog(path: home + "/log.jsonl")
        let result = CacheCleaner.clean(targets, resolver: CommandResolver(searchPaths: []), home: home, log: log)
        close(held)

        let outcomes = Dictionary(uniqueKeysWithValues: result.outcomes.map { ($0.id, $0) })
        #expect(outcomes["t/debug/incremental"]?.succeeded == false)
        #expect(outcomes["t/debug/incremental"]?.error?.contains("locked") == true)
        #expect(fm.fileExists(atPath: target + "/debug/incremental/app-1/s-1/dep-graph.bin"))
        #expect(outcomes["t/release/incremental"]?.succeeded == true)
        #expect(!fm.fileExists(atPath: target + "/release/incremental"))
        #expect(fm.fileExists(atPath: target + "/release/deps/libapp-1.rlib"))
        #expect(fm.fileExists(atPath: target + "/release/bundle/macos/App.app/Contents/MacOS/App"))
    }

    @Test func binariesInUseBlockOrWarn() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let target = home + "/shared"
        try makeTargetDir(target)
        let definition = CacheDefinition(id: "t", title: "t", category: .build, safety: .regenerable, paths: [target],
                                         fallback: .none, itemRule: .cargoProfiles(buildDirDepth: 0))

        // A real process running a binary from the release profile (copies of system binaries are
        // killed by macOS, so build a tiny one).
        try write(home + "/sleeper.c", "#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n")
        let compiler = try Process.run(URL(fileURLWithPath: "/usr/bin/cc"), arguments: [home + "/sleeper.c", "-o", target + "/release/sleeper"])
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { return }  // no toolchain
        let process = try Process.run(URL(fileURLWithPath: target + "/release/sleeper"), arguments: [])
        defer { process.terminate() }
        for _ in 0..<40 where !InUseIndex.runningExecutablePaths().contains(where: { $0.hasSuffix("/release/sleeper") }) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try write(home + "/.claude.json", "{\"mcpServers\":{\"x\":{\"command\":\"\(target)/debug/server\"}}}")
        try fm.createDirectory(atPath: home + "/.local/bin", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: home + "/.local/bin/tool", withDestinationPath: target + "/debug/deps/libapp-1.rlib")

        let inUse = InUseIndex.snapshot(home: home)
        let report = scan([definition], home: home, inUse: inUse)
        let release = try #require(report.item(id: "t/release"))
        #expect(release.blockedReason?.contains("sleeper is running") == true)
        let debug = try #require(report.item(id: "t/debug"))
        #expect(debug.isCleanable)
        #expect(debug.reason?.contains(".claude.json") == true && debug.reason?.contains(".local/bin/tool") == true)
        // Incremental dirs hold no binaries: still offered.
        #expect(report.item(id: "t/release/incremental")?.isPreselectable == true)
    }

    // MARK: Terraform

    @Test func providerVersionsInUseAreKept() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        let cache = home + "/.terraform.d/plugin-cache/registry.terraform.io/hashicorp"
        let old = Date().addingTimeInterval(-90 * 86_400)
        for version in ["6.62.0", "6.67.0", "6.74.0"] {
            try write("\(cache)/aws/\(version)/darwin_arm64/terraform-provider-aws", bytes: 1_000)
            for path in ["/darwin_arm64/terraform-provider-aws", "/darwin_arm64", ""] {
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: "\(cache)/aws/\(version)" + path)
            }
        }
        try write(home + "/proj/.terraform.lock.hcl", """
            provider "registry.terraform.io/hashicorp/aws" {
              version     = "6.62.0"
              constraints = "~> 6.0"
              hashes = ["h1:abc"]
            }
            """)
        try fm.createDirectory(atPath: home + "/proj/.terraform", withIntermediateDirectories: true)
        #expect(TerraformUsage.referencedVersions(terraformDirs: [home + "/proj/.terraform"]) == ["registry.terraform.io/hashicorp/aws/6.62.0"])

        let definition = try #require(CacheCatalog.definitions(environment: [:], home: home).first { $0.id == "terraform-plugins" })
        var options = CacheScanner.Options(definitions: [definition], home: home, resolver: CommandResolver(searchPaths: []), workerCount: 2)
        let unknown = CacheScanner.scan(options)
        #expect(unknown.entry(id: "terraform-plugins")?.recommendedItems.isEmpty == true, "usage unknown: nothing suggested")

        options.terraformDirs = [home + "/proj/.terraform"]
        let known = CacheScanner.scan(options)
        let items = Dictionary(uniqueKeysWithValues: (known.entry(id: "terraform-plugins")?.items ?? []).map { ($0.name, $0) })
        #expect(items["registry.terraform.io/hashicorp/aws/6.67.0"]?.isRecommended == true)
        #expect(items["registry.terraform.io/hashicorp/aws/6.62.0"]?.isRecommended == false)
        #expect(items["registry.terraform.io/hashicorp/aws/6.74.0"]?.isRecommended == false, "newest is kept")
        #expect(known.allSafeIDs.isEmpty, "re-downloads are never preselected")
    }

    // MARK: Doctor configures it → DiskCare measures it

    @Test func everyLocationDoctorConfiguresIsCatalogued() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/bin/sccache", "#!/bin/sh\n")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/bin/sccache")
        let environment = ["PATH": home + "/bin"]
        let context = DoctorContext(home: home, environment: environment, runCommand: { _, _, _ in nil }, measureSizes: false)

        for check in Doctor.checks where check.supportsAutoFix {
            if let change = try check.proposedChange(context) { _ = try change.apply(now: Date()) }
            let locations = check.managedLocations(context)
            #expect(!locations.isEmpty, "\(check.id) configures something")
            for location in locations { try fm.createDirectory(atPath: location, withIntermediateDirectories: true) }
            let covered = CacheCatalog.definitions(environment: environment, home: home).flatMap { $0.resolvedPaths(home: home) }
            for location in locations {
                let normalized = ScanOptions.normalize(location)
                #expect(covered.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }, "\(check.id): \(location) is not measured")
            }
        }
    }

    @Test func customTerraformCacheDirIsCatalogued() throws {
        let home = try makeHome()
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/.terraformrc", "plugin_cache_dir = \"$HOME/tf-cache\"\n")
        try fm.createDirectory(atPath: home + "/tf-cache", withIntermediateDirectories: true)
        let definition = try #require(CacheCatalog.definitions(environment: [:], home: home).first { $0.id == "terraform-plugins" })
        #expect(definition.resolvedPaths(home: home) == [home + "/tf-cache"])
    }
}
