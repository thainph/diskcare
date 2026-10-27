import Foundation

public struct GitInfo: Sendable, Codable, Equatable {
    public var branch: String?
    public var lastCommitAt: Date?
    /// Last time HEAD moved (commit, checkout, reset…), from the mtime of the HEAD reflog.
    public var lastHeadMoveAt: Date?
    /// Number of `git status --porcelain` lines (modified + untracked, ignored files excluded).
    public var uncommittedChanges: Int
    /// First base ref that already contains HEAD (e.g. `origin/develop`). Squash merges are not detected.
    public var mergedInto: String?
}

/// Reads repository state through the `git` CLI, which handles worktrees correctly.
public enum GitInspector {
    private static let baseRefs = [
        "refs/remotes/origin/HEAD", "refs/remotes/origin/main", "refs/remotes/origin/master",
        "refs/remotes/origin/develop", "refs/heads/main", "refs/heads/master", "refs/heads/develop",
    ]
    private static let baseBranchNames: Set<String> = ["main", "master", "develop"]

    /// Inspects repositories in parallel; results keep the input order.
    /// `git status` walks the whole worktree, so concurrency is capped (tightly for background scans).
    public static func inspect(_ paths: [String], priority: ScanPriority = .userInitiated) -> [GitInfo?] {
        let results = LockedArray<GitInfo?>(repeating: nil, count: paths.count)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = priority == .background ? 2 : 6
        queue.qualityOfService = priority.qualityOfService
        for index in paths.indices {
            queue.addOperation {
                priority.applyToCurrentThread()
                results[index] = inspect(paths[index])
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        return results.values
    }

    public static func inspect(_ path: String) -> GitInfo? {
        guard let branch = run(path, ["rev-parse", "--abbrev-ref", "HEAD"]) else { return nil }
        let lastCommit = run(path, ["log", "-1", "--format=%ct"]).flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
        let status = run(path, ["status", "--porcelain", "--untracked-files=normal", "--ignore-submodules"]) ?? ""
        let changes = status.split(separator: "\n").count

        var mergedInto: String?
        if !baseBranchNames.contains(branch) {
            let existing = run(path, ["for-each-ref", "--format=%(refname:short)"] + baseRefs)?
                .split(separator: "\n").map(String.init) ?? []
            mergedInto = existing.first { ref in
                ref != branch && run(path, ["merge-base", "--is-ancestor", "HEAD", ref]) != nil
            }
        }
        let lastHeadMove = run(path, ["rev-parse", "--absolute-git-dir"]).flatMap { gitDir in
            (try? FileManager.default.attributesOfItem(atPath: gitDir + "/logs/HEAD"))?[.modificationDate] as? Date
        }
        return GitInfo(
            branch: branch, lastCommitAt: lastCommit, lastHeadMoveAt: lastHeadMove,
            uncommittedChanges: changes, mergedInto: mergedInto
        )
    }

    /// Main repository of a linked worktree, read from its `.git` file (`gitdir: <repo>/.git/worktrees/<name>`).
    public static func mainRepository(ofWorktree path: String) -> String? {
        guard let content = try? String(contentsOfFile: path + "/.git", encoding: .utf8),
              let line = content.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        let gitDir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitDir[..<range.lowerBound])
    }

    /// Runs git and returns trimmed stdout, or nil on a non-zero exit.
    private static func run(_ directory: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory] + arguments
        // Children inherit the caller's priority (background scans spawn background git).
        process.qualityOfService = Thread.current.qualityOfService
        // Read-only inspection must not take index.lock or touch the index.
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Fixed-size array written from concurrent iterations, one slot per index.
final class LockedArray<Element>: @unchecked Sendable {
    private var storage: [Element]
    private let lock = NSLock()

    init(repeating value: Element, count: Int) {
        storage = Array(repeating: value, count: count)
    }

    subscript(index: Int) -> Element {
        get { lock.withLock { storage[index] } }
        set { lock.withLock { storage[index] = newValue } }
    }

    var values: [Element] { lock.withLock { storage } }
}
