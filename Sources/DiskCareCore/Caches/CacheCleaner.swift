import Darwin
import Foundation

/// One thing to clean: a whole cache entry or a single item inside it.
public struct CacheCleanTarget: Sendable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case entry, item
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let safety: CacheSafety
    /// Entry: the cache directories. Item: the item directory.
    public let paths: [String]
    /// Directories an item must stay strictly inside (the entry's paths).
    public let containers: [String]
    public let bytes: Int64
    public let nativeCommand: NativeCleanCommand?
    public let fallback: CacheFallback

    /// Human-readable plan for this target in the given mode.
    public func action(mode: CleanupMode, resolver: CommandResolver) -> String {
        if kind == .item { return mode == .trash ? "trash dir" : "delete dir" }
        if let command = CacheCleaner.nativeCommand(for: self, mode: mode), resolver.resolve(command) != nil {
            return "run: \(command.display)"
        }
        guard fallback == .deleteContents else { return "not cleanable (no command)" }
        return mode == .trash ? "trash contents" : "delete contents"
    }
}

public struct CacheCleanOutcome: Sendable, Codable, Identifiable {
    public var id: String { target.id }
    public let target: CacheCleanTarget
    public let succeeded: Bool
    /// What was actually done (`brew cleanup -s`, `delete contents`…).
    public let action: String
    public let command: CommandResult?
    public let error: String?
}

public struct CacheCleanResult: Sendable, Codable {
    public let outcomes: [CacheCleanOutcome]
    public let freeBytesBefore: Int64?
    public let freeBytesAfter: Int64?

    /// Measured change in free space (only meaningful in delete mode).
    public var freedBytes: Int64? {
        guard let freeBytesBefore, let freeBytesAfter else { return nil }
        return freeBytesAfter - freeBytesBefore
    }
}

public enum CacheCleanError: Error, CustomStringConvertible {
    case unknownID(String)
    case userData(String)
    case notCleanable(String)

    public var description: String {
        switch self {
        case .unknownID(let id): "unknown cache id: \(id)"
        case .userData(let id): "\(id) holds user data and is never cleaned by DiskCare"
        case .notCleanable(let id): "\(id) cannot be cleaned (no cleanup command available)"
        }
    }
}

public enum CacheCleaner {
    /// Builds targets from ids (`homebrew`, `playwright/chromium-1228`). An item whose entry is also
    /// selected is dropped. Throws for unknown ids and for anything that must not be cleaned.
    public static func targets(ids: [String], in report: CacheReport) throws -> [CacheCleanTarget] {
        var targets: [CacheCleanTarget] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            if let entry = report.entry(id: id) {
                guard entry.safety.isCleanable else { throw CacheCleanError.userData(id) }
                guard entry.isCleanable else { throw CacheCleanError.notCleanable(id) }
                targets.append(CacheCleanTarget(
                    id: entry.id, kind: .entry, title: entry.title, safety: entry.safety, paths: entry.paths,
                    containers: entry.paths, bytes: entry.bytes, nativeCommand: entry.nativeCommand, fallback: entry.fallback
                ))
            } else if let item = report.item(id: id), let entry = report.entry(id: item.entryID) {
                guard entry.safety.isCleanable else { throw CacheCleanError.userData(id) }
                targets.append(CacheCleanTarget(
                    id: item.id, kind: .item, title: "\(entry.title): \(item.name)", safety: entry.safety, paths: [item.path],
                    containers: entry.paths, bytes: item.bytes, nativeCommand: nil, fallback: .deleteContents
                ))
            } else {
                throw CacheCleanError.unknownID(id)
            }
        }
        let wholeEntries = Set(targets.filter { $0.kind == .entry }.map(\.id))
        return targets.filter { target in
            target.kind == .entry || !wholeEntries.contains(where: { target.id.hasPrefix($0 + "/") })
        }
    }

    /// Cleans targets in parallel and measures free space before and after.
    public static func clean(
        _ targets: [CacheCleanTarget],
        mode: CleanupMode = .delete,
        resolver: CommandResolver = .standard(),
        home: String = NSHomeDirectory(),
        progress: (@Sendable (CacheCleanOutcome) -> Void)? = nil
    ) -> CacheCleanResult {
        let freeBefore = Cleaner.availableCapacity(at: home)
        let results = LockedArray<CacheCleanOutcome?>(repeating: nil, count: targets.count)
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let outcome = clean(targets[index], mode: mode, resolver: resolver, home: home)
            results[index] = outcome
            progress?(outcome)
        }
        return CacheCleanResult(
            outcomes: results.values.compactMap { $0 },
            freeBytesBefore: freeBefore,
            freeBytesAfter: Cleaner.availableCapacity(at: home)
        )
    }

    /// Native commands delete permanently, so in Trash mode they are only used when there is no fallback.
    static func nativeCommand(for target: CacheCleanTarget, mode: CleanupMode) -> NativeCleanCommand? {
        guard let command = target.nativeCommand else { return nil }
        return mode == .trash && target.fallback == .deleteContents ? nil : command
    }

    static func clean(_ target: CacheCleanTarget, mode: CleanupMode, resolver: CommandResolver, home: String) -> CacheCleanOutcome {
        func outcome(_ action: String, _ command: CommandResult? = nil, error: String? = nil) -> CacheCleanOutcome {
            CacheCleanOutcome(target: target, succeeded: error == nil, action: action, command: command, error: error)
        }
        guard target.safety.isCleanable else {
            return outcome("skipped", error: CacheCleanError.userData(target.id).description)
        }

        if target.kind == .item {
            let path = target.paths.first ?? ""
            if let problem = Cleaner.validate(path, roots: target.containers) {
                return outcome("skipped", error: problem)
            }
            do {
                try remove(path, mode: mode)
                return outcome(mode == .trash ? "trash dir" : "delete dir")
            } catch {
                return outcome("delete dir", error: "\(error)")
            }
        }

        var commandResult: CommandResult?
        if let command = nativeCommand(for: target, mode: mode), let executable = resolver.resolve(command) {
            let result = CommandRunner.run(
                executable: executable, arguments: command.arguments,
                timeout: command.timeoutSeconds, searchPaths: resolver.searchPaths
            )
            if result.succeeded { return outcome("run: \(command.display)", result) }
            commandResult = result
            guard target.fallback == .deleteContents else {
                let reason = result.timedOut ? "timed out" : "exit \(result.exitCode)"
                return outcome("run: \(command.display)", result, error: "\(command.display) failed (\(reason)): \(result.output.suffix(300))")
            }
        }
        guard target.fallback == .deleteContents else {
            return outcome("skipped", error: CacheCleanError.notCleanable(target.id).description)
        }

        let action = (commandResult != nil ? "command failed, " : "") + (mode == .trash ? "trash contents" : "delete contents")
        var errors: [String] = []
        for path in target.paths {
            if let problem = checkCacheRoot(path, home: home) {
                errors.append("\(path.abbreviatingHome): \(problem)")
                continue
            }
            errors += deleteContents(of: path, mode: mode)
        }
        return outcome(action, commandResult, error: errors.isEmpty ? nil : errors.prefix(3).joined(separator: "; "))
    }

    /// Last line of defence before emptying a directory: it must still be a real directory and not
    /// one of the broad locations that merely contain caches.
    static func checkCacheRoot(_ path: String, home: String) -> String? {
        let normalized = ScanOptions.normalize(path)
        guard normalized == path, path.hasPrefix("/") else { return "path is not normalized" }
        let protected = ["/", "/Users", home, home + "/Library", home + "/Library/Caches", home + "/Library/Application Support",
                         home + "/.cache", home + "/.config", home + "/.local", home + "/.local/share", home + "/Library/Developer"]
        guard !protected.contains(path) else { return "refusing to empty a top-level directory" }
        guard path.split(separator: "/").count >= 3 else { return "path too shallow" }
        guard CachePaths.isRealDirectory(path) else { return "not a directory (missing or symlink?)" }
        return nil
    }

    /// Deletes every child of `root` and keeps `root` itself. Read-only trees (Go modules) are
    /// made writable and retried once.
    static func deleteContents(of root: String, mode: CleanupMode) -> [String] {
        var errors: [String] = []
        for attempt in 0..<2 {
            errors = []
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
            for name in names {
                do {
                    try remove(root + "/" + name, mode: mode)
                } catch {
                    errors.append("\(name): \(error)")
                }
            }
            guard !errors.isEmpty, attempt == 0, mode == .delete else { break }
            makeWritable(root)
        }
        return errors
    }

    static func remove(_ path: String, mode: CleanupMode) throws {
        if mode == .trash {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return
        }
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        if (info.st_mode & S_IFMT) == S_IFDIR {
            try Cleaner.removeTree(path)
        } else if unlink(path) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func makeWritable(_ root: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-R", "u+w", root]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }
}
