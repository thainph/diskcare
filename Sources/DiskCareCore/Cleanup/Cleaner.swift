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

public enum CleanupError: Error, CustomStringConvertible {
    /// Moved aside but not fully deleted; the staging directory is left for the next cleanup.
    case partiallyRemoved(staging: String, underlying: String)

    public var description: String {
        switch self {
        case .partiallyRemoved(let staging, let underlying):
            "\(underlying); partially deleted, leftover at \(staging.abbreviatingHome)"
        }
    }
}

/// Executes a cleanup plan. Every candidate is re-validated right before it is touched.
public enum Cleaner {
    public static func execute(
        _ candidates: [CleanupCandidate],
        roots: [String],
        mode: CleanupMode,
        log: DeletionLog = .standard,
        progress: (@Sendable (CleanupOutcome) -> Void)? = nil
    ) -> [CleanupOutcome] {
        let artifacts = candidates.filter { $0.action == .deleteArtifact }
        let worktrees = candidates.filter { $0.action == .removeWorktree }
        let results = LockedArray<CleanupOutcome?>(repeating: nil, count: candidates.count)
        let guardrail = DeletionGuard(roots: roots)

        func finish(_ outcome: CleanupOutcome, mode: String) -> CleanupOutcome {
            let candidate = outcome.candidate
            log.append(DeletionRecord(
                path: candidate.path, bytes: candidate.bytes, mode: mode,
                source: candidate.action == .removeWorktree ? "worktree" : "artifact", result: outcome.error ?? "ok"
            ))
            progress?(outcome)
            return outcome
        }

        // Artifacts are independent directories: delete in parallel.
        DispatchQueue.concurrentPerform(iterations: artifacts.count) { index in
            results[index] = finish(deleteArtifact(artifacts[index], guardrail: guardrail, mode: mode), mode: mode.rawValue)
        }
        // Worktrees of one repository share git locks: remove sequentially.
        for (offset, candidate) in worktrees.enumerated() {
            results[artifacts.count + offset] = finish(removeWorktree(candidate, guardrail: guardrail), mode: "git worktree remove")
        }
        return results.values.compactMap { $0 }
    }

    /// Checks that a path is still a real directory strictly inside one of the scan roots
    /// (and not a protected location); see `DeletionGuard`.
    static func validate(_ path: String, roots: [String]) -> String? {
        DeletionGuard(roots: roots).checkRemoval(path)
    }

    private static func deleteArtifact(_ candidate: CleanupCandidate, guardrail: DeletionGuard, mode: CleanupMode) -> CleanupOutcome {
        if let problem = guardrail.checkRemoval(candidate.path) {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: problem)
        }
        do {
            switch mode {
            case .trash:
                try FileManager.default.trashItem(at: URL(fileURLWithPath: candidate.path), resultingItemURL: nil)
            case .delete where candidate.kind == .cleanupLeftover:
                try removeStaged(candidate.path, original: candidate.path)
            case .delete:
                try removeTree(candidate.path)
            }
            return CleanupOutcome(candidate: candidate, succeeded: true, error: nil)
        } catch {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: "\(error)")
        }
    }

    /// Prefix of the directory a tree is renamed to while it is being deleted. One left behind
    /// (crash, permission error) is listed by the next scan as a leftover to finish.
    public static let stagingPrefix = ".diskcare-deleting-"

    /// Renames the directory out of the way first (atomic for the project), then removes it
    /// with removefile(3), which is much faster than FileManager for large trees.
    static func removeTree(_ path: String) throws {
        let parent = (path as NSString).deletingLastPathComponent
        let staging = parent + "/" + stagingPrefix + UUID().uuidString
        let target = rename(path, staging) == 0 ? staging : path
        try removeStaged(target, original: path)
    }

    /// Removes a directory that is already out of the way (renamed, or a leftover staging dir).
    static func removeStaged(_ target: String, original: String) throws {
        do {
            if let removefile = systemRemovefile {
                guard removefile(target, nil, removefileRecursive) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            } else {
                try FileManager.default.removeItem(atPath: target)
            }
        } catch {
            guard target != original else { throw error }
            throw CleanupError.partiallyRemoved(staging: target, underlying: "\(error)")
        }
    }

    // removefile.h is not exported to Swift by the SDK module map, so bind the libSystem symbol directly.
    private typealias RemovefileFunction = @convention(c) (UnsafePointer<CChar>, OpaquePointer?, UInt32) -> Int32
    private static let removefileRecursive: UInt32 = 1 << 0  // REMOVEFILE_RECURSIVE
    private static let systemRemovefile: RemovefileFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        return dlsym(defaultHandle, "removefile").map { unsafeBitCast($0, to: RemovefileFunction.self) }
    }()

    private static func removeWorktree(_ candidate: CleanupCandidate, guardrail: DeletionGuard) -> CleanupOutcome {
        if let problem = guardrail.checkRemoval(candidate.path) {
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
