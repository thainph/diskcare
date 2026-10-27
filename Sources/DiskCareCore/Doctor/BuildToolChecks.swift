import Foundation

enum Savings {
    /// Total size of `kind` artifacts minus the `keepCopies` largest, which a shared cache/target still holds.
    static func duplicates(of kind: ArtifactKind, in report: ScanReport?, keepCopies: Int) -> (count: Int, total: Int64, savings: Int64)? {
        guard let report else { return nil }
        let sizes = report.artifacts.filter { $0.kind == kind }.map(\.totals.bytes).sorted(by: >)
        guard !sizes.isEmpty else { return (0, 0, 0) }
        let total = sizes.reduce(0, +)
        let kept = sizes.prefix(keepCopies).reduce(0, +)
        return (sizes.count, total, total - kept)
    }

    static let significant: Int64 = 1_000_000_000

    /// Savings worth reporting; tiny remainders (symlink-only dirs) are noise.
    static func shown(_ bytes: Int64?) -> Int64? {
        bytes.flatMap { $0 >= 1_000_000 ? $0 : nil }
    }
}

/// Terraform downloads every provider (the AWS one is ~0.7 GB) into each working dir's `.terraform`
/// unless a plugin cache is configured; with it, `.terraform` only holds symlinks.
public struct TerraformPluginCacheCheck: DoctorCheck {
    public let id = "terraform-plugin-cache"
    public let title = "Terraform provider plugin cache"
    public var supportsAutoFix: Bool { true }

    public init() {}

    /// `TF_CLI_CONFIG_FILE` (environment, then shell rc files) or `~/.terraformrc`.
    func configPath(_ context: DoctorContext) -> String {
        if let path = context.environment["TF_CLI_CONFIG_FILE"], !path.isEmpty { return TerraformRC.expand(path, home: context.home) }
        if let export = context.shellExports(of: "TF_CLI_CONFIG_FILE").first, !export.value.isEmpty {
            return TerraformRC.expand(export.value, home: context.home)
        }
        return context.home + "/.terraformrc"
    }

    /// Three kept copies approximate the distinct provider sets the cache will still hold.
    public static func estimatedSavings(_ report: ScanReport?) -> Int64? {
        Savings.duplicates(of: .terraform, in: report, keepCopies: 3)?.savings
    }

    public func evaluate(_ context: DoctorContext) -> CheckResult {
        let path = configPath(context)
        let text = context.read(path)
        let fileCache = text.flatMap { TerraformRC.value(of: TerraformRC.cacheDirKey, in: $0) }
        let lockFlag = text.flatMap { TerraformRC.value(of: TerraformRC.lockFileKey, in: $0) }
        let envCache = context.environment["TF_PLUGIN_CACHE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let shellCache = context.shellExports(of: "TF_PLUGIN_CACHE_DIR")
        let usage = Savings.duplicates(of: .terraform, in: context.report, keepCopies: 3)

        var details: [String] = []
        details.append(text == nil ? "\(path.abbreviatingHome): not found" : "\(path.abbreviatingHome): \(TerraformRC.cacheDirKey) = \(fileCache.map { "\"\($0)\"" } ?? "(unset)")")
        if let envCache { details.append("TF_PLUGIN_CACHE_DIR=\(envCache) (current environment)") }
        for export in shellCache { details.append("TF_PLUGIN_CACHE_DIR=\(export.value) exported in \(export.file.abbreviatingHome)") }
        if let usage, usage.count > 0 {
            details.append("\(usage.count) .terraform dirs use \(ByteFormat.string(usage.total))")
        }
        let reinitHint = "Existing .terraform dirs keep full provider copies until re-initialised: run `terraform init` in active ones, "
            + "delete idle ones with `diskcare clean --kind .terraform --idle-days 7 --apply`."

        var missingKeys: [String] = []
        if fileCache == nil { missingKeys.append("`\(TerraformRC.cacheDirKey) = \"\(TerraformRC.defaultCacheDir)\"`") }
        if lockFlag == nil { missingKeys.append("`\(TerraformRC.lockFileKey) = true`") }
        let fix = "Add \(missingKeys.joined(separator: " and ")) to \(path.abbreviatingHome) "
            + (text == nil ? "(new file). " : "(existing file backed up first). ") + reinitHint
        let savings = Savings.shown(usage?.savings)

        if let fileCache {
            let cacheDir = TerraformRC.expand(fileCache, home: context.home)
            if !context.fileExists(cacheDir) { details.append("cache dir \(cacheDir.abbreviatingHome) does not exist (Terraform ignores a missing cache dir)") }
            if lockFlag == nil {
                return CheckResult(
                    id: id, title: title, status: .info,
                    finding: "Plugin cache is enabled, but \(TerraformRC.lockFileKey) is unset: Terraform ≥ 1.4 re-downloads providers whose checksums are missing from .terraform.lock.hcl.",
                    details: details, estimatedSavingsBytes: savings, fix: fix, isAutoFixable: true, fixTargetPath: path
                )
            }
            if let savings, savings >= Savings.significant {
                return CheckResult(
                    id: id, title: title, status: .info,
                    finding: "Plugin cache is enabled, but \(ByteFormat.string(savings)) of .terraform dirs still hold their own provider copies.",
                    details: details, estimatedSavingsBytes: savings, fix: reinitHint, isAutoFixable: false, fixTargetPath: path
                )
            }
            return CheckResult(id: id, title: title, status: .ok, finding: "Plugin cache is enabled in \(path.abbreviatingHome).", details: details, estimatedSavingsBytes: savings)
        }
        if envCache != nil || !shellCache.isEmpty {
            return CheckResult(
                id: id, title: title, status: .info,
                finding: "Plugin cache is only set through TF_PLUGIN_CACHE_DIR; IDEs, GUI apps and wrappers that drop the environment still download providers per directory.",
                details: details, estimatedSavingsBytes: savings, fix: fix, isAutoFixable: true, fixTargetPath: path
            )
        }
        return CheckResult(
            id: id, title: title, status: .warning,
            finding: "No provider plugin cache configured: every `terraform init` (each worktree, each module) downloads its own provider binaries.",
            details: details, estimatedSavingsBytes: savings, fix: fix, isAutoFixable: true, fixTargetPath: path
        )
    }

    public func proposedChange(_ context: DoctorContext) throws -> ConfigChange? {
        let path = configPath(context)
        let original = context.read(path)
        guard let merged = TerraformRC.merged(original) else { return nil }
        let cacheDir = TerraformRC.expand(
            original.flatMap { TerraformRC.value(of: TerraformRC.cacheDirKey, in: $0) } ?? TerraformRC.defaultCacheDir,
            home: context.home
        )
        return ConfigChange(
            path: path, originalContents: original, newContents: merged, directoriesToCreate: [cacheDir],
            followUp: [
                "Re-run `terraform init` in active working dirs so .terraform links into \(cacheDir.abbreviatingHome).",
                "Delete idle .terraform dirs: `diskcare clean --kind .terraform --idle-days 7 --apply`.",
            ]
        )
    }
}

/// Without a shared `target-dir`, every Rust project (and every worktree of it) compiles all dependencies again.
public struct CargoSharedTargetCheck: DoctorCheck {
    public let id = "cargo-shared-target"
    public let title = "Cargo shared target directory"
    public var supportsAutoFix: Bool { true }

    public init() {}

    func cargoHome(_ context: DoctorContext) -> String {
        context.environment["CARGO_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? context.home + "/.cargo"
    }

    /// `config.toml`, or the legacy extensionless `config` when only that exists.
    func configPath(_ context: DoctorContext) -> String {
        let home = cargoHome(context)
        if !context.fileExists(home + "/config.toml"), context.fileExists(home + "/config") { return home + "/config" }
        return home + "/config.toml"
    }

    func sharedTargetDir(_ context: DoctorContext) -> String { cargoHome(context) + "/target-shared" }

    /// The shared target still holds roughly the largest project's build.
    public static func estimatedSavings(_ report: ScanReport?) -> Int64? {
        Savings.duplicates(of: .cargoTarget, in: report, keepCopies: 1)?.savings
    }

    public func evaluate(_ context: DoctorContext) -> CheckResult {
        let path = configPath(context)
        let text = context.read(path)
        let fileTarget = text.flatMap(CargoConfig.targetDir(in:))
        let envTarget = context.environment["CARGO_TARGET_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let shellTarget = context.shellExports(of: "CARGO_TARGET_DIR")
        let usage = Savings.duplicates(of: .cargoTarget, in: context.report, keepCopies: 1)

        var details: [String] = []
        details.append(text == nil ? "\(path.abbreviatingHome): not found" : "\(path.abbreviatingHome): build.target-dir = \(fileTarget.map { "\"\($0)\"" } ?? "(unset)")")
        if let envTarget { details.append("CARGO_TARGET_DIR=\(envTarget) (current environment)") }
        for export in shellTarget { details.append("CARGO_TARGET_DIR=\(export.value) exported in \(export.file.abbreviatingHome)") }
        if let usage, usage.count > 0 { details.append("\(usage.count) cargo target dirs use \(ByteFormat.string(usage.total))") }
        if ProcessRunner.locate("cargo-sweep", environment: context.environment, home: context.home) == nil
            && !context.fileExists(cargoHome(context) + "/bin/cargo-sweep") {
            details.append("Tip: `cargo install cargo-sweep`, then `cargo sweep --time 30 -r <dir>` trims stale build artifacts.")
        }

        let target = sharedTargetDir(context)
        let fix = "Add `[build] target-dir = \"\(target)\"` to \(path.abbreviatingHome) \(text == nil ? "(new file)" : "(existing file backed up first)"). "
            + "Trade-offs: builds of different projects share one lock, `cargo clean` wipes the shared dir, binaries move to \(target.abbreviatingHome)/{debug,release}. "
            + "Delete old per-project target dirs with `diskcare clean --kind cargo-target`."
        let savings = Savings.shown(usage?.savings)

        if fileTarget != nil {
            return CheckResult(id: id, title: title, status: .ok, finding: "Shared target-dir is configured in \(path.abbreviatingHome).", details: details, estimatedSavingsBytes: savings)
        }
        if envTarget != nil || !shellTarget.isEmpty {
            return CheckResult(
                id: id, title: title, status: .info,
                finding: "Shared target dir only set through CARGO_TARGET_DIR; IDEs (rust-analyzer) and GUI tools may not see it.",
                details: details, estimatedSavingsBytes: savings, fix: fix, isAutoFixable: true, fixTargetPath: path
            )
        }
        let large = (usage?.total ?? 0) >= Savings.significant
        return CheckResult(
            id: id, title: title, status: large ? .warning : .info,
            finding: "Each Rust project and worktree builds its dependencies into its own target/ directory.",
            details: details, estimatedSavingsBytes: savings, fix: fix, isAutoFixable: true, fixTargetPath: path
        )
    }

    public func proposedChange(_ context: DoctorContext) throws -> ConfigChange? {
        let path = configPath(context)
        let original = context.read(path)
        guard let merged = CargoConfig.merged(original, targetDir: sharedTargetDir(context)) else { return nil }
        return ConfigChange(
            path: path, originalContents: original, newContents: merged,
            followUp: ["Delete old per-project target dirs: `diskcare clean --kind cargo-target --idle-days 0` (review the plan first)."]
        )
    }
}
