import Darwin
import Foundation

/// What currently points into build output: running executables, command symlinks, LaunchAgents and
/// MCP/IDE configs. A binary built into a shared target dir is often run straight from there.
public struct InUseIndex: Sendable {
    /// Executable paths of running processes (canonical).
    let runningExecutables: [String]
    /// `(symlink, resolved target)` from the usual bin directories.
    let commandLinks: [(link: String, target: String)]
    /// `(file, contents)` of LaunchAgent plists and MCP/IDE configs.
    let referencingFiles: [(file: String, text: String)]

    init(runningExecutables: [String], commandLinks: [(link: String, target: String)], referencingFiles: [(file: String, text: String)]) {
        self.runningExecutables = runningExecutables
        self.commandLinks = commandLinks
        self.referencingFiles = referencingFiles
    }

    public static let empty = InUseIndex(runningExecutables: [], commandLinks: [], referencingFiles: [])

    public static func snapshot(home: String = NSHomeDirectory(), cargoHome: String? = nil, scanRoots: [String] = []) -> InUseIndex {
        let binDirectories = [home + "/.local/bin", home + "/bin", "/usr/local/bin", "/opt/homebrew/bin", (cargoHome ?? home + "/.cargo") + "/bin"]
        var links: [(String, String)] = []
        for directory in binDirectories {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                let link = directory + "/" + name
                guard (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) != nil else { continue }
                // realpath(3), not Foundation's resolver, which strips `/private` and would not match.
                guard let resolved = realpath(link, nil) else { continue }
                links.append((link, String(cString: resolved)))
                free(resolved)
            }
        }
        var files = ((try? FileManager.default.contentsOfDirectory(atPath: home + "/Library/LaunchAgents")) ?? [])
            .filter { $0.hasSuffix(".plist") }.map { home + "/Library/LaunchAgents/" + $0 }
        files += [
            home + "/.claude.json", home + "/.codex/config.toml", home + "/.cursor/mcp.json",
            home + "/Library/Application Support/Claude/claude_desktop_config.json",
        ]
        files += scanRoots.map { $0 + "/.vscode/settings.json" }
        let texts = files.compactMap { file -> (String, String)? in
            readText(file).map { (file, $0) }
        }
        return InUseIndex(runningExecutables: runningExecutablePaths(), commandLinks: links, referencingFiles: texts)
    }

    /// A process runs an executable from inside `prefix`: deleting it would pull the binary from under it.
    public func runningReason(under prefix: String) -> String? {
        let canonical = Self.canonical(prefix)
        guard let path = runningExecutables.first(where: { $0.hasPrefix(canonical + "/") }) else { return nil }
        return "\((path as NSString).lastPathComponent) is running from here"
    }

    /// Softer signs of use (a command symlink, a LaunchAgent, an MCP config) that only warrant a warning.
    public func referenceReasons(under prefix: String) -> [String] {
        let canonical = Self.canonical(prefix)
        var reasons: [String] = []
        if let link = commandLinks.first(where: { $0.target.hasPrefix(canonical + "/") }) {
            reasons.append("linked from \(link.link.abbreviatingHome)")
        }
        let spellings = Set([prefix, canonical])
        for file in referencingFiles where spellings.contains(where: { file.text.contains($0 + "/") }) {
            reasons.append("referenced in \(file.file.abbreviatingHome)")
        }
        return reasons
    }

    static func canonical(_ path: String) -> String {
        DeletionGuard.canonicalDirectory(path) ?? path
    }

    /// Small text files only: configs, not logs that happen to share a name.
    private static func readText(_ path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? Int, size < 4_000_000 else { return nil }
        if path.hasSuffix(".plist"), let plist = NSDictionary(contentsOfFile: path) {
            return "\(plist)"
        }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Executable paths of every process `proc_pidpath` can read (other users' processes may be missing).
    static func runningExecutablePaths() -> [String] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var paths = Set<String>()
        for pid in pids.prefix(Int(max(0, filled))) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            paths.insert(String(cString: buffer))
        }
        return paths.sorted()
    }
}
