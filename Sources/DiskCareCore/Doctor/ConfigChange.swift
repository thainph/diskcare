import Foundation

/// A proposed edit of one config file, computed without touching disk.
public struct ConfigChange: Sendable, Codable, Equatable {
    public let path: String
    /// nil when the file does not exist yet.
    public let originalContents: String?
    public let newContents: String
    /// Directories to create alongside the edit (e.g. the Terraform plugin cache).
    public let directoriesToCreate: [String]
    /// What the user still has to do for the change to take effect.
    public let followUp: [String]

    public init(path: String, originalContents: String?, newContents: String, directoriesToCreate: [String] = [], followUp: [String] = []) {
        self.path = path
        self.originalContents = originalContents
        self.newContents = newContents
        self.directoriesToCreate = directoriesToCreate
        self.followUp = followUp
    }

    public var diff: String {
        LineDiff.unified(old: originalContents ?? "", new: newContents, path: path.abbreviatingHome, isNewFile: originalContents == nil)
    }

    /// Backs up the existing file (`<path>.diskcare-backup-<timestamp>`) and writes the new contents.
    /// Fails if the file changed since the change was proposed. Symlinked dotfiles are edited in place.
    public func apply(now: Date = Date()) throws -> AppliedChange {
        let fileManager = FileManager.default
        let current = try? String(contentsOfFile: path, encoding: .utf8)
        guard current == originalContents else { throw DoctorError.fileChangedSinceProposal(path) }

        var backupPath: String?
        if originalContents != nil {
            let backup = Self.backupPath(for: path, now: now)
            try fileManager.copyItem(atPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path, toPath: backup)
            backupPath = backup
        }
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(newContents.utf8).write(to: target, options: .atomic)
        for directory in directoriesToCreate {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        return AppliedChange(path: path, backupPath: backupPath, followUp: followUp)
    }

    static func backupPath(for path: String, now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(path).diskcare-backup-\(formatter.string(from: now))"
        var candidate = base
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate) {
            counter += 1
            candidate = "\(base)-\(counter)"
        }
        return candidate
    }
}

public struct AppliedChange: Sendable, Codable {
    public let path: String
    public let backupPath: String?
    public let followUp: [String]
}

/// Minimal LCS line diff, enough for small config files.
enum LineDiff {
    static func unified(old: String, new: String, path: String, isNewFile: Bool, context: Int = 2) -> String {
        let a = lines(old), b = lines(new)
        // lcs[i][j] = LCS length of a[i...] and b[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops: [(Character, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                ops.append((" ", a[i])); i += 1; j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                ops.append(("+", b[j])); j += 1
            } else {
                ops.append(("-", a[i])); i += 1
            }
        }
        // Keep changed lines plus `context` unchanged lines around them.
        let changed = ops.indices.filter { ops[$0].0 != " " }
        var output = ["--- \(isNewFile ? "/dev/null" : path)", "+++ \(path)"]
        var lastPrinted = -1
        for index in ops.indices where changed.contains(where: { abs($0 - index) <= context }) {
            if lastPrinted >= 0, index > lastPrinted + 1 { output.append("@@ … @@") }
            output.append("\(ops[index].0)\(ops[index].1)")
            lastPrinted = index
        }
        return output.joined(separator: "\n")
    }

    private static func lines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}

/// Runs short-lived helper commands (`pnpm --version`, `tmutil`…) with a hard timeout.
public enum ProcessRunner {
    public static let run: CommandRunner = { executable, arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        // Script shims (`#!/usr/bin/env node`) need their own directory on PATH, e.g. nvm's bin.
        let directory = (executable as NSString).deletingLastPathComponent
        environment["PATH"] = ([directory] + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain stdout concurrently so a chatty process cannot block on a full pipe.
        let data = LockedArray<Data>(repeating: Data(), count: 1)
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data[0] = output.fileHandleForReading.readDataToEndOfFile()
            reader.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        _ = reader.wait(timeout: .now() + 1)
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data[0], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// First executable named `name` on PATH or in the usual install locations (GUI apps get a minimal PATH).
    public static func locate(_ name: String, environment: [String: String], home: String) -> String? {
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += [
            home + "/Library/pnpm", home + "/.local/share/pnpm", home + "/.volta/bin",
            "/opt/homebrew/bin", "/usr/local/bin",
        ]
        // nvm: newest installed Node version first.
        let nvm = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            directories += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(nvm)/\($0)/bin" }
        }
        return directories.lazy.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
