import Darwin
import Foundation

/// Safety rules for a Cargo build directory found through user configuration. A path from config
/// is untrusted (it could be the home directory); only one that looks exactly like Cargo's own
/// output is ever offered for cleanup.
public enum CargoBuildDirectory {
    /// Written by Cargo into every target/build dir it creates.
    static let cacheDirTagSignature = "Signature: 8a477f597d28d172789f06886806bc55"

    /// Top-level children Cargo itself creates (besides profiles and target triples).
    static let knownTopLevel: Set<String> = [
        "debug", "release", "doc", "package", "tmp", "rust-analyzer", "CACHEDIR.TAG", ".rustc_info.json",
        ".cargo-lock",
    ]

    /// Directories Cargo creates inside a profile. `bundle` (Tauri installers) is known but holds
    /// output that is not a cache.
    static let knownProfileDirectories: Set<String> = [".fingerprint", "build", "deps", "examples", "incremental", "bundle"]

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
        knownTopLevel.contains(name) || name.hasPrefix("flycheck") || Cleaner.isStagingName(name)
            || isProfile(path + "/" + name) || isTargetTriple(name)
    }

    /// A profile directory (`debug`, `release`, custom `[profile.x]`) has Cargo's `.fingerprint` dir.
    static func isProfile(_ path: String) -> Bool {
        CachePaths.isRealDirectory(path + "/.fingerprint")
    }

    /// `aarch64-apple-darwin`, `wasm32-unknown-unknown`, `x86_64-unknown-linux-gnu`…
    static func isTargetTriple(_ name: String) -> Bool {
        name.split(separator: "-").count >= 3 && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }

    /// Profile directories of one build dir: `<profile>` and `<triple>/<profile>`, relative paths.
    static func profiles(in buildDir: String) -> [String] {
        let children = ((try? FileManager.default.contentsOfDirectory(atPath: buildDir)) ?? []).sorted()
        var profiles: [String] = []
        for name in children where !name.hasPrefix(".") {
            if isProfile(buildDir + "/" + name) {
                profiles.append(name)
            } else if isTargetTriple(name) {
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
        if let stranger = directories.first(where: { !knownProfileDirectories.contains($0) && !Cleaner.isStagingName($0) }) {
            return (nil, "contains \(stranger)/, which Cargo does not create")
        }
        if directories.contains("bundle") { return ("holds installers in bundle/ (.app/.dmg)", nil) }
        return (nil, nil)
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
