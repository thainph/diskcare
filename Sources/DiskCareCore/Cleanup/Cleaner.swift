import Darwin
import Foundation

public enum CleanupMode: String, Sendable, Codable {
    /// Remove immediately (frees space now). Fine for regenerable artifacts.
    case delete
    /// Move to the user's Trash (space is only freed once the Trash is emptied).
    case trash
}

public struct CleanupOutcome: Sendable, Codable {
    public let candidate: CleanupCandidate
    public let succeeded: Bool
    public let error: String?
}

/// Executes a cleanup plan. Every candidate is re-validated right before it is touched.
public enum Cleaner {
    public static func execute(
        _ candidates: [CleanupCandidate],
        roots: [String],
        mode: CleanupMode,
        progress: (@Sendable (CleanupOutcome) -> Void)? = nil
    ) -> [CleanupOutcome] {
        let artifacts = candidates.filter { $0.action == .deleteArtifact }
        let worktrees = candidates.filter { $0.action == .removeWorktree }
        let results = LockedArray<CleanupOutcome?>(repeating: nil, count: candidates.count)

        // Artifacts are independent directories: delete in parallel.
        DispatchQueue.concurrentPerform(iterations: artifacts.count) { index in
            let outcome = deleteArtifact(artifacts[index], roots: roots, mode: mode)
            results[index] = outcome
            progress?(outcome)
        }
        // Worktrees of one repository share git locks: remove sequentially.
        for (offset, candidate) in worktrees.enumerated() {
            let outcome = removeWorktree(candidate, roots: roots)
            results[artifacts.count + offset] = outcome
            progress?(outcome)
        }
        return results.values.compactMap { $0 }
    }

    /// Checks that a path is still a real directory strictly inside one of the scan roots.
    static func validate(_ path: String, roots: [String]) -> String? {
        let normalized = ScanOptions.normalize(path)
        guard normalized == path else { return "path is not normalized" }
        guard roots.contains(where: { path.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else { return "outside scan roots" }
        var info = stat()
        guard lstat(path, &info) == 0 else { return "no longer exists" }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return "not a directory (symlink?)" }
        return nil
    }

    private static func deleteArtifact(_ candidate: CleanupCandidate, roots: [String], mode: CleanupMode) -> CleanupOutcome {
        if let problem = validate(candidate.path, roots: roots) {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: problem)
        }
        do {
            switch mode {
            case .trash:
                try FileManager.default.trashItem(at: URL(fileURLWithPath: candidate.path), resultingItemURL: nil)
            case .delete:
                try removeTree(candidate.path)
            }
            return CleanupOutcome(candidate: candidate, succeeded: true, error: nil)
        } catch {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: "\(error)")
        }
    }

    /// Renames the directory out of the way first (atomic for the project), then removes it
    /// with removefile(3), which is much faster than FileManager for large trees.
    static func removeTree(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let staging = parent + "/.diskcare-deleting-" + UUID().uuidString
        let target = rename(path, staging) == 0 ? staging : path
        guard let removefile = systemRemovefile else {
            try FileManager.default.removeItem(atPath: target)
            return
        }
        guard removefile(target, nil, removefileRecursive) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // removefile.h is not exported to Swift by the SDK module map, so bind the libSystem symbol directly.
    private typealias RemovefileFunction = @convention(c) (UnsafePointer<CChar>, OpaquePointer?, UInt32) -> Int32
    private static let removefileRecursive: UInt32 = 1 << 0  // REMOVEFILE_RECURSIVE
    private static let systemRemovefile: RemovefileFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "removefile").map { unsafeBitCast($0, to: RemovefileFunction.self) }
    }()

    private static func removeWorktree(_ candidate: CleanupCandidate, roots: [String]) -> CleanupOutcome {
        if let problem = validate(candidate.path, roots: roots) {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: problem)
        }
        guard let repository = candidate.mainRepositoryPath else {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: "main repository unknown")
        }
        // Re-check right before removal: no --force, so git itself refuses dirty or untracked content.
        guard let git = GitInspector.inspect(candidate.path), git.uncommittedChanges == 0, git.mergedInto != nil else {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: "worktree changed since scan")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", repository, "worktree", "remove", candidate.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
            let message = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return CleanupOutcome(candidate: candidate, succeeded: false, error: text)
            }
            return CleanupOutcome(candidate: candidate, succeeded: true, error: nil)
        } catch {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: "\(error)")
        }
    }

    /// Free space available for important usage on the volume containing `path`.
    public static func availableCapacity(at path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
