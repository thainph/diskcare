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
    /// The directory at the path is not the one that was checked (replaced, or now a symlink).
    case changed(String)
    /// The owning tool holds its lock (a build is running).
    case locked(String)

    public var description: String {
        switch self {
        case .changed(let path): "\(path.abbreviatingHome) changed since it was checked"
        case .locked(let lockFile): "in use: \(lockFile.abbreviatingHome) is locked (build running?)"
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

        // Logged before as well, so a crash mid-delete still leaves a trace.
        func start(_ candidate: CleanupCandidate, mode: String) -> CleanupCandidate {
            log.append(DeletionRecord(
                path: candidate.path, bytes: candidate.bytes, mode: mode,
                source: candidate.action == .removeWorktree ? "worktree" : "artifact", result: "started"
            ))
            return candidate
        }

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
            let candidate = start(artifacts[index], mode: mode.rawValue)
            results[index] = finish(deleteArtifact(candidate, guardrail: guardrail, mode: mode), mode: mode.rawValue)
        }
        // Worktrees of one repository share git locks: remove sequentially.
        for (offset, candidate) in worktrees.enumerated() {
            _ = start(candidate, mode: "git worktree remove")
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
        let verdict = guardrail.approveRemoval(candidate.path)
        if let problem = verdict.problem {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: problem)
        }
        do {
            switch mode {
            case .trash:
                try trash(candidate.path, expected: verdict.identity)
            case .delete where candidate.kind == .cleanupLeftover:
                try verify(candidate.path, expected: verdict.identity)
                try removeStaged(candidate.path, original: candidate.path)
            case .delete:
                try removeTree(candidate.path, expected: verdict.identity)
            }
            return CleanupOutcome(candidate: candidate, succeeded: true, error: nil)
        } catch {
            return CleanupOutcome(candidate: candidate, succeeded: false, error: "\(error)")
        }
    }

    /// Prefix of the directory a tree is renamed to while it is being deleted. One left behind
    /// (crash, permission error) is listed by the next scan as a leftover to finish.
    public static let stagingPrefix = ".diskcare-deleting-"

    /// `.diskcare-deleting-<UUID>` exactly, so a user directory that merely starts alike is never taken for one.
    public static func isStagingName(_ name: String) -> Bool {
        name.hasPrefix(stagingPrefix) && UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil
    }

    /// Renames the directory out of the way first (atomic for the project), then removes it
    /// with removefile(3), which is much faster than FileManager for large trees. `expected` is the
    /// identity a guard approved: the directory actually renamed must still be that one.
    static func removeTree(_ path: String, expected: DeletionGuard.FileID? = nil) throws {
        let staging = try moveAside(path, expected: expected)
        try removeStaged(staging, original: path)
    }

    /// Renames a real directory to a staging name next to it and checks it is the expected one.
    static func moveAside(_ path: String, expected: DeletionGuard.FileID?) throws -> String {
        let before = try verify(path, expected: expected)
        let staging = (path as NSString).deletingLastPathComponent + "/" + stagingPrefix + UUID().uuidString
        guard rename(path, staging) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var after = stat()
        guard lstat(staging, &after) == 0, DeletionGuard.FileID(after) == before else {
            _ = rename(staging, path)
            throw CleanupError.changed(path)
        }
        return staging
    }

    /// The path must be a real directory (not a symlink) with the expected identity.
    @discardableResult
    static func verify(_ path: String, expected: DeletionGuard.FileID?) throws -> DeletionGuard.FileID {
        var info = stat()
        guard DeletionGuard.pathProblem(path) == nil, lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw CleanupError.changed(path)
        }
        let identity = DeletionGuard.FileID(info)
        if let expected, identity != expected { throw CleanupError.changed(path) }
        return identity
    }

    static func trash(_ path: String, expected: DeletionGuard.FileID?) throws {
        try verify(path, expected: expected)
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    /// Like `removeTree`, but first takes the tool's lock without waiting (a running build holds it)
    /// and keeps it until the directory has been renamed away; the slow delete happens after.
    static func removeTree(_ path: String, mode: CleanupMode, expected: DeletionGuard.FileID?, holdingLock lockFile: String) throws {
        let descriptor = open(lockFile, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor >= 0 {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                close(descriptor)
                throw CleanupError.locked(lockFile)
            }
        } else if errno != ENOENT {
            // A lock that exists but cannot be opened (symlink, permissions) is not proof that no build runs.
            throw CleanupError.locked(lockFile)
        }
        let staging: String
        do {
            defer { if descriptor >= 0 { close(descriptor) } }
            if mode == .trash {
                try trash(path, expected: expected)
                return
            }
            staging = try moveAside(path, expected: expected)
        }
        try removeStaged(staging, original: path)
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
        if let problem = guardrail.approveRemoval(candidate.path).problem {
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

    /// Free space on the volume containing `path`, as `df` reports it. Use this to measure what a
    /// cleanup freed: the important-usage value also counts purgeable space and moves on its own.
    public static func availableCapacity(at path: String) -> Int64? {
        VolumeSpace.available(at: path)
    }

    /// Free space for important usage (includes purgeable space) on the volume containing `path`.
    public static func importantAvailableCapacity(at path: String) -> Int64? {
        VolumeSpace.importantAvailable(at: path)
    }
}
