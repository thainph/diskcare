import Foundation
import Testing
@testable import DiskCareCore

@Suite struct DoctorTests {
    /// Temporary fake home directory; never the real one.
    private final class TempHome {
        let path: String
        init() throws {
            path = FileManager.default.temporaryDirectory.appendingPathComponent("diskcare-doctor-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(atPath: path) }

        func write(_ relative: String, _ contents: String) throws {
            let url = URL(fileURLWithPath: path + "/" + relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }

        func read(_ relative: String) -> String? { try? String(contentsOfFile: path + "/" + relative, encoding: .utf8) }

        func files(prefix: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasPrefix(prefix) }
        }
    }

    private func context(_ home: TempHome, environment: [String: String] = [:], report: ScanReport? = nil) -> DoctorContext {
        DoctorContext(home: home.path, environment: environment, report: report, runCommand: { _, _, _ in nil }, measureSizes: false)
    }

    private func report(_ artifacts: [(String, ArtifactKind, Int64)]) -> ScanReport {
        let entries = artifacts.map { path, kind, bytes in
            var totals = Totals()
            totals.bytes = bytes
            return ArtifactEntry(path: path, kind: kind, totals: totals, workspacePath: nil, projectLastChangeAt: nil)
        }
        return ScanReport(roots: ["/w"], scannedAt: Date(), stats: ScanStats(), gitDurationSeconds: 0, artifacts: entries, workspaces: [])
    }

    // MARK: Terraform

    @Test func terraformWarnsWithoutCacheAndFixCreatesFile() throws {
        let home = try TempHome()
        let check = TerraformPluginCacheCheck()
        #expect(check.evaluate(context(home)).status == .warning)

        let applied = try #require(try Doctor.apply(check.id, context: context(home)))
        #expect(applied.backupPath == nil)
        let text = try #require(home.read(".terraformrc"))
        #expect(TerraformRC.value(of: "plugin_cache_dir", in: text) == "$HOME/.terraform.d/plugin-cache")
        #expect(TerraformRC.value(of: "plugin_cache_may_break_dependency_lock_file", in: text) == "true")
        #expect(FileManager.default.fileExists(atPath: home.path + "/.terraform.d/plugin-cache"))
        #expect(check.evaluate(context(home)).status == .ok)

        // Idempotent: nothing left to change, file untouched.
        #expect(try Doctor.apply(check.id, context: context(home)) == nil)
        #expect(home.read(".terraformrc") == text)
    }

    @Test func terraformMergeKeepsExistingValuesAndBacksUp() throws {
        let home = try TempHome()
        let cacheDir = home.path + "/custom-cache"
        let original = """
        # mine
        plugin_cache_dir = "\(cacheDir)" // keep
        provider_installation {
          plugin_cache_may_break_dependency_lock_file = true
          direct {}
        }
        """
        try home.write(".terraformrc", original)
        let check = TerraformPluginCacheCheck()
        // The key inside a block does not count as the top-level setting.
        let result = check.evaluate(context(home))
        #expect(result.status == .info)
        #expect(result.isAutoFixable)

        let change = try #require(try check.proposedChange(context(home)))
        #expect(change.directoriesToCreate == [cacheDir])
        #expect(change.diff.contains("+plugin_cache_may_break_dependency_lock_file = true"))
        #expect(!change.diff.contains("+plugin_cache_dir"))

        let applied = try change.apply(now: Date(timeIntervalSince1970: 0))
        let backup = try #require(applied.backupPath)
        #expect(try String(contentsOfFile: backup, encoding: .utf8) == original)
        #expect(home.files(prefix: ".terraformrc.diskcare-backup-").count == 1)

        let merged = try #require(home.read(".terraformrc"))
        #expect(merged.hasPrefix(original))
        #expect(merged.components(separatedBy: "plugin_cache_dir").count == 2)
        #expect(TerraformRC.merged(merged) == nil)
    }

    @Test func terraformDetectsEnvironmentAndShellExports() throws {
        let home = try TempHome()
        try home.write(".zshrc", "# export TF_PLUGIN_CACHE_DIR=/commented\nexport TF_PLUGIN_CACHE_DIR=\"$HOME/.tfcache\"\n")
        let result = TerraformPluginCacheCheck().evaluate(context(home))
        #expect(result.status == .info)
        #expect(result.details.contains { $0.contains("$HOME/.tfcache") && $0.contains(".zshrc") })

        let fromEnv = TerraformPluginCacheCheck().evaluate(context(home, environment: ["TF_PLUGIN_CACHE_DIR": "/x"]))
        #expect(fromEnv.details.contains { $0.contains("current environment") })
    }

    @Test func terraformHonoursCliConfigFile() throws {
        let home = try TempHome()
        let env = ["TF_CLI_CONFIG_FILE": "$HOME/tf/cli.tfrc"]
        let change = try #require(try TerraformPluginCacheCheck().proposedChange(context(home, environment: env)))
        #expect(change.path == home.path + "/tf/cli.tfrc")
    }

    @Test func applyRefusesWhenFileChangedSinceProposal() throws {
        let home = try TempHome()
        let change = try #require(try TerraformPluginCacheCheck().proposedChange(context(home)))
        try home.write(".terraformrc", "credentials \"x\" {}\n")
        #expect(throws: DoctorError.self) { try change.apply() }
    }

    @Test func terraformSavingsKeepThreeLargestCopies() {
        let gb: Int64 = 1_000_000_000
        let report = report([
            ("/w/a/.terraform", .terraform, 2 * gb), ("/w/b/.terraform", .terraform, gb),
            ("/w/c/.terraform", .terraform, gb), ("/w/d/.terraform", .terraform, gb),
            ("/w/e/.terraform", .terraform, gb), ("/w/r/target", .cargoTarget, 5 * gb),
        ])
        #expect(TerraformPluginCacheCheck.estimatedSavings(report) == 2 * gb)
        #expect(TerraformPluginCacheCheck.estimatedSavings(nil) == nil)
        #expect(CargoSharedTargetCheck.estimatedSavings(report) == 0)
    }

    // MARK: Cargo

    @Test func cargoInsertsUnderExistingBuildTable() throws {
        let home = try TempHome()
        try home.write(".cargo/config.toml", "[net]\ngit-fetch-with-cli = true\n\n[build]\njobs = 8\n\n[alias]\nb = \"build\"\n")
        let check = CargoSharedTargetCheck()
        #expect(check.evaluate(context(home)).isAutoFixable)

        let applied = try #require(try Doctor.apply(check.id, context: context(home)))
        let backup = try #require(applied.backupPath)
        #expect(try String(contentsOfFile: backup, encoding: .utf8).hasPrefix("[net]"))
        let text = try #require(home.read(".cargo/config.toml"))
        #expect(text.components(separatedBy: "[build]").count == 2)
        #expect(text.contains("[build]\ntarget-dir = \"\(home.path)/.cargo/target-shared\""))
        #expect(CargoConfig.targetDir(in: text) == home.path + "/.cargo/target-shared")
        #expect(check.evaluate(context(home)).status == .ok)
        #expect(try Doctor.apply(check.id, context: context(home)) == nil)
    }

    @Test func cargoAppendsBuildTableOrCreatesFile() throws {
        #expect(CargoConfig.merged(nil, targetDir: "/t")?.hasPrefix("[build]\ntarget-dir = \"/t\"") == true)
        let appended = try #require(CargoConfig.merged("[net]\nretry = 3", targetDir: "/t"))
        #expect(appended.hasPrefix("[net]\nretry = 3\n\n[build]\ntarget-dir = \"/t\""))
    }

    @Test func cargoDetectsAllTargetDirSpellings() {
        #expect(CargoConfig.targetDir(in: "build.target-dir = \"/a\"") == "/a")
        #expect(CargoConfig.targetDir(in: "[build]\n# target-dir = \"/no\"\ntarget-dir = '/b' # yes") == "/b")
        #expect(CargoConfig.targetDir(in: "build = { jobs = 2, target-dir = \"/c\" }") == "/c")
        #expect(CargoConfig.targetDir(in: "[target.x86_64]\ntarget-dir = \"/no\"") == nil)
        #expect(CargoConfig.targetDir(in: "[build]\n# target-dir = \"/no\"") == nil)
    }

    @Test func cargoUsesLegacyConfigAndCargoHome() throws {
        let home = try TempHome()
        try home.write(".cargo/config", "[build]\ntarget-dir = \"/x\"\n")
        #expect(CargoSharedTargetCheck().evaluate(context(home)).status == .ok)
        let custom = CargoSharedTargetCheck().configPath(context(home, environment: ["CARGO_HOME": "/opt/cargo"]))
        #expect(custom == "/opt/cargo/config.toml")
    }

    // MARK: Node / system

    @Test func npmProjectsAreDetectedFromLockFiles() throws {
        let home = try TempHome()
        for (dir, lock) in [("npm", "package-lock.json"), ("yarn", "yarn.lock"), ("pnpm", "pnpm-lock.yaml"), ("none", "package.json")] {
            try home.write("\(dir)/\(lock)", "{}")
        }
        try home.write("mixed/package-lock.json", "{}")
        try home.write("mixed/pnpm-lock.yaml", "")
        let report = report(["npm", "yarn", "pnpm", "none", "mixed"].enumerated().map { index, dir in
            ("\(home.path)/\(dir)/node_modules", .nodeModules, Int64(100 - index))
        })
        let projects = NpmToPnpmCheck.projects(in: report)
        #expect(projects.map(\.manager) == ["npm", "yarn"])
        #expect(projects.first?.path == home.path + "/npm")

        let result = NpmToPnpmCheck().evaluate(context(home, report: report))
        #expect(result.status == .info)
        #expect(!result.isAutoFixable)
    }

    @Test func pnpmVersionGate() {
        #expect(PnpmGlobalVirtualStoreCheck.supports(version: "10.12.0"))
        #expect(PnpmGlobalVirtualStoreCheck.supports(version: "11.0.1"))
        #expect(!PnpmGlobalVirtualStoreCheck.supports(version: "10.11.9"))
        #expect(!PnpmGlobalVirtualStoreCheck.supports(version: "9.15.9"))
        #expect(!PnpmGlobalVirtualStoreCheck.supports(version: "garbage"))
    }

    @Test func dockerGCAndSnapshotParsing() {
        let parsed = DockerBuildCacheGCCheck.gcSettings(#"{"builder":{"gc":{"enabled":true,"defaultKeepStorage":"20GB"}}}"#)
        #expect(parsed?.enabled == true && parsed?.keepStorage == "20GB")
        #expect(DockerBuildCacheGCCheck.gcSettings("{}") == nil)
        let output = "Snapshots for disk /:\ncom.apple.TimeMachine.2026-10-27-101010.local\ncom.apple.TimeMachine.2026-10-27-111010.local\n"
        #expect(TimeMachineSnapshotsCheck.snapshotCount(output) == 2)
        #expect(TimeMachineSnapshotsCheck.snapshotCount("Snapshots for disk /:") == 0)
    }

    @Test func nonFixableChecksRejectApply() throws {
        let home = try TempHome()
        #expect(throws: DoctorError.self) { try Doctor.apply("npm-to-pnpm", context: context(home)) }
        #expect(throws: DoctorError.self) { try Doctor.apply("nope", context: context(home)) }
    }

    @Test func diffShowsOnlyChangedLinesWithContext() {
        let diff = LineDiff.unified(old: "a\nb\nc\nd\ne\nf\n", new: "a\nb\nc\nd\ne\nf\ng\n", path: "x", isNewFile: false)
        #expect(diff == "--- x\n+++ x\n e\n f\n+g")
    }
}
