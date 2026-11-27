import Darwin
import Foundation

/// A Cargo build directory configured outside the projects (`build.target-dir`, `build.build-dir`,
/// `CARGO_TARGET_DIR`). Such a directory is shared by every project and never goes stale, so
/// DiskCare measures it as a cache and offers its `incremental` dirs for cleanup.
public struct CargoBuildLocation: Sendable, Codable, Equatable {
    /// Where the location came from, e.g. `~/.cargo/config.toml: build.target-dir`.
    public let source: String
    /// The resolved directory. For a templated `build-dir` this is the part before the first
    /// per-workspace template: it holds one build dir per workspace below `buildDirDepth` levels.
    public let path: String
    /// 0 = `path` is itself a build dir; 2 = `{workspace-path-hash}` levels in between.
    public let buildDirDepth: Int
}

/// Finds Cargo build directories the way Cargo resolves them. Read-only; never runs cargo.
public enum CargoBuildLocator {
    public static func locate(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        scanRoots: [String] = []
    ) -> [CargoBuildLocation] {
        let cargoHome = self.cargoHome(home: home, environment: environment)
        var found: [CargoBuildLocation] = []

        if let value = ShellRC.value(of: "CARGO_TARGET_DIR", environment: environment, home: home), value.hasPrefix("/") {
            found.append(CargoBuildLocation(source: "CARGO_TARGET_DIR", path: value, buildDirDepth: 0))
        }
        if let value = ShellRC.value(of: "CARGO_BUILD_BUILD_DIR", environment: environment, home: home),
           let location = buildDir(value, source: "CARGO_BUILD_BUILD_DIR", base: nil, cargoHome: cargoHome) {
            found.append(location)
        }
        for file in configFiles(cargoHome: cargoHome, scanRoots: scanRoots) {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            // Relative paths are relative to the directory containing the `.cargo` directory.
            let base = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
            if let value = CargoConfig.value(of: "build.target-dir", in: text), !value.contains("{"),
               let path = resolve(value, base: base) {
                found.append(CargoBuildLocation(source: "\(file.abbreviatingHome): build.target-dir", path: path, buildDirDepth: 0))
            }
            if let value = CargoConfig.value(of: "build.build-dir", in: text),
               let location = buildDir(value, source: "\(file.abbreviatingHome): build.build-dir", base: base, cargoHome: cargoHome) {
                found.append(location)
            }
        }
        return deduplicated(found)
    }

    /// `CARGO_HOME` from the environment, then shell rc files (GUI apps do not see them), else `~/.cargo`.
    public static func cargoHome(home: String, environment: [String: String]) -> String {
        ShellRC.value(of: "CARGO_HOME", environment: environment, home: home).flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? home + "/.cargo"
    }

    /// `$CARGO_HOME/config.toml` (or legacy `config`), plus `.cargo/config.toml` in every scan root and
    /// its ancestors: Cargo merges config files hierarchically from the project upwards.
    static func configFiles(cargoHome: String, scanRoots: [String]) -> [String] {
        var directories: [String] = []
        for root in scanRoots {
            var current = ScanOptions.normalize(root)
            while true {
                directories.append(current + "/.cargo")
                if current == "/" { break }
                current = (current as NSString).deletingLastPathComponent
            }
        }
        directories.append(cargoHome)
        var seen = Set<String>()
        return directories.compactMap { directory -> String? in
            guard seen.insert(directory).inserted else { return nil }
            for name in ["config.toml", "config"] where FileManager.default.fileExists(atPath: directory + "/" + name) {
                return directory + "/" + name
            }
            return nil
        }
    }

    /// `build-dir` templates: `{cargo-cache-home}` resolves; `{workspace-path-hash}` (two levels) and
    /// `{workspace-root}` do not, so the location is the prefix before them. Inside a workspace
    /// (`{workspace-root}`) it is the project's business and is skipped.
    static func buildDir(_ value: String, source: String, base: String?, cargoHome: String) -> CargoBuildLocation? {
        let expanded = value.replacingOccurrences(of: "{cargo-cache-home}", with: cargoHome)
        guard !expanded.contains("{workspace-root}") else { return nil }
        let components = expanded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let templated = components.firstIndex(where: { $0.contains("{") }) else {
            return resolve(expanded, base: base).map { CargoBuildLocation(source: source, path: $0, buildDirDepth: 0) }
        }
        // Only a trailing `{workspace-path-hash}` is understood; anything else is not measured.
        guard components[templated...] == ["{workspace-path-hash}"] else { return nil }
        let prefix = components[..<templated].joined(separator: "/")
        return resolve(prefix, base: base).map { CargoBuildLocation(source: source, path: $0, buildDirDepth: 2) }
    }

    /// Absolute, normalized path; nil when relative without a base. `~` is not expanded (Cargo does not).
    static func resolve(_ value: String, base: String?) -> String? {
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("/") { return ScanOptions.normalize(value) }
        guard let base, !value.hasPrefix("~") else { return nil }
        return ScanOptions.normalize(base + "/" + value)
    }

    /// The same directory reached twice is kept once; a location inside another is dropped.
    static func deduplicated(_ locations: [CargoBuildLocation]) -> [CargoBuildLocation] {
        var seen = Set<DeletionGuard.FileID>()
        var unique: [(location: CargoBuildLocation, canonical: String)] = []
        for location in locations {
            let canonical = DeletionGuard.canonicalDirectory(location.path) ?? location.path
            if let id = DeletionGuard.identity(followingLinks: canonical) {
                guard seen.insert(id).inserted else { continue }
            } else if unique.contains(where: { $0.canonical == canonical }) {
                continue
            }
            unique.append((location, canonical))
        }
        return unique.filter { candidate in
            !unique.contains { $0.canonical != candidate.canonical && candidate.canonical.hasPrefix($0.canonical + "/") }
        }.map(\.location)
    }
}
