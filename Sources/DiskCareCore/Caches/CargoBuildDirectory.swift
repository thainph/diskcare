import Darwin
import Foundation

/// Safety rules for a Cargo build directory found through user configuration. A path from config
/// is untrusted (it could be the home directory); only one that looks exactly like Cargo's own
/// output is ever offered for cleanup.
public enum CargoBuildDirectory {
    /// Written by Cargo into every target/build dir it creates.
    static let cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// Top-level directories Cargo and its usual companions create (besides profiles and target triples).
    static let knownTopLevelDirectories: Set<String> = ["debug", "release", "doc", "package", "tmp", "rust-analyzer", "nextest", "llvm-cov-target"]

    /// Top-level files Cargo, rustdoc and Finder write.
    static let knownTopLevelFiles: Set<String> = [
        "CACHEDIR.TAG", ".rustc_info.json", ".rustdoc_fingerprint.json", ".future-incompat-report.json",
        ".cargo-lock", ".package-cache", ".DS_Store",
    ]

    /// Directories Cargo creates inside a profile. `bundle` (Tauri installers) is known but holds
    /// output that is not a cache; `*.dSYM` are debug symbols of the binaries next to them.
    static let knownProfileDirectories: Set<String> = [".fingerprint", "build", "deps", "examples", "incremental", "bundle"]

    /// Files that look like an app's own data (written by a binary run from the profile), not build output.
    static let dataFileExtensions: Set<String> = ["db", "sqlite", "sqlite3", "log", "json", "toml", "yaml", "yml", "csv"]

    /// First component of every Rust target triple in use.
    static let architectures: Set<String> = [
        "aarch64", "arm64", "arm64e", "x86_64", "i686", "i586", "i386", "wasm32", "wasm64", "armv7", "armv7s", "armv7a",
        "thumbv6m", "thumbv7m", "thumbv7em", "thumbv8m.main", "riscv32imac", "riscv32imc", "riscv64gc", "powerpc64le", "s390x",
        "mips", "mipsel", "loongarch64", "nvptx64", "sparc64", "x86_64h",
    ]

    /// Why the directory must stay report-only; nil when it passes every check.
    public static func gateProblem(_ path: String, guardrail: DeletionGuard) -> String? {
        if let problem = guardrail.checkUntrusted(path) { return problem }
        guard let tag = try? String(contentsOfFile: path + "/CACHEDIR.TAG", encoding: .utf8),
              tag.hasPrefix(cacheDirTagSignature) else { return "no Cargo CACHEDIR.TAG" }
        for marker in [".git", "Cargo.toml"] where FileManager.default.fileExists(atPath: path + "/" + marker) {
            return "contains \(marker): looks like a project, not a build dir"
        }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        if let stranger = children.first(where: { !isKnownTopLevel($0, in: path) }) {
            return "contains \(stranger), which Cargo does not create"
        }
        return nil
    }

    static func isKnownTopLevel(_ name: String, in path: String) -> Bool {
        let child = path + "/" + name
        guard CachePaths.isRealDirectory(child) else {
            return knownTopLevelFiles.contains(name)
        }
        return knownTopLevelDirectories.contains(name) || name.hasPrefix("flycheck") || Cleaner.isStagingName(name)
            || isProfile(child) || isTargetTriple(name, at: child)
    }

    /// A profile directory (`debug`, `release`, custom `[profile.x]`) has Cargo's `.fingerprint` dir.
    static func isProfile(_ path: String) -> Bool {
        CachePaths.isRealDirectory(path + "/.fingerprint")
    }

    /// `aarch64-apple-darwin`, `wasm32-unknown-unknown`, `x86_64-unknown-linux-gnu`…: a real directory
    /// named after a known architecture that holds only profiles (and Finder's `.DS_Store`).
    static func isTargetTriple(_ name: String, at path: String) -> Bool {
        let parts = name.split(separator: "-")
        guard parts.count >= 2, architectures.contains(String(parts[0])), CachePaths.isRealDirectory(path) else { return false }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        return children.allSatisfy { $0 == ".DS_Store" || isProfile(path + "/" + $0) || Cleaner.isStagingName($0) }
    }

    /// Profile directories of one build dir: `<profile>` and `<triple>/<profile>`, relative paths.
    static func profiles(in buildDir: String) -> [String] {
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: buildDir)) ?? []).sorted()
        var profiles: [String] = []
        for name in children where !name.hasPrefix(".") {
            if isProfile(buildDir + "/" + name) {
                profiles.append(name)
            } else if isTargetTriple(name, at: buildDir + "/" + name) {
                let nested = ((try? FileManager.default.contentsOfDirectory(atPath: buildDir + "/" + name)) ?? []).sorted()
                profiles += nested.filter { isProfile(buildDir + "/" + name + "/" + $0) }.map { name + "/" + $0 }
            }
        }
        return profiles
    }

    /// What deleting a whole profile would lose beyond rebuildable output; nil when it is pure build output.
    /// Unknown directories (benchmark baselines…) make the profile report-only.
    static func profileHazard(_ profilePath: String) -> (warning: String?, blocker: String?) {
        let children = (try? FileManager.default.contentsOfDirectory(atPath: profilePath)) ?? []
        let directories = children.filter { CachePaths.isRealDirectory(profilePath + "/" + $0) }
        if let stranger = directories.first(where: {
            !knownProfileDirectories.contains($0) && !$0.hasSuffix(".dSYM") && !Cleaner.isStagingName($0)
        }) {
            return (nil, "contains \(stranger)/, which Cargo does not create")
        }
        let dataFiles = children.filter { name in
            !directories.contains(name) && dataFileExtensions.contains((name as NSString).pathExtension.lowercased())
        }
        var warnings: [String] = []
        if directories.contains("bundle") { warnings.append("holds installers in bundle/ (.app/.dmg)") }
        if let file = dataFiles.first { warnings.append("holds \(file), which looks like app data, not build output") }
        return (warnings.isEmpty ? nil : warnings.joined(separator: "; "), nil)
    }

    /// The lock Cargo holds (flock) while building into a profile.
    static func lockFile(forItemAt path: String) -> String? {
        var current = path
        for _ in 0..<2 {
            if FileManager.default.fileExists(atPath: current + "/.cargo-lock") { return current + "/.cargo-lock" }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

extension DeletionGuard {
    /// Why a directory taken from user configuration must not be cleaned at all: it must be a real
    /// directory and neither a protected location, a root, nor an ancestor of one.
    public func checkUntrusted(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "path is not absolute" }
        guard let canonical = Self.canonicalDirectory(path), let id = Self.identity(followingLinks: canonical) else {
            return "not a real directory (missing or symlink?)"
        }
        if protectedChain.contains(id) { return "is a protected location or contains one" }
        if rootChain.contains(id) { return "is a scan root or contains one" }
        return nil
    }
}
