import Darwin
import Foundation

/// Finds tool binaries the way a login shell would, even when launched from Finder with a bare PATH.
public struct CommandResolver: Sendable {
    public var searchPaths: [String]

    public init(searchPaths: [String]) {
        var seen = Set<String>()
        self.searchPaths = searchPaths.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// PATH first, then the usual install locations (Homebrew, ~/.local/bin, nvm, pyenv…).
    public static func standard(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CommandResolver {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        var extra = [
            "/opt/homebrew/bin", "/usr/local/bin",
            home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.bun/bin",
            home + "/Library/pnpm", home + "/.volta/bin", home + "/.pyenv/shims",
        ]
        // nvm: the newest installed node first (its bin holds npm, pnpm/yarn shims).
        let nvmVersions = home + "/.nvm/versions/node"
        let nodes = ((try? FileManager.default.contentsOfDirectory(atPath: nvmVersions)) ?? [])
            .sorted { VersionNumber($0) > VersionNumber($1) }
        extra += nodes.map { nvmVersions + "/" + $0 + "/bin" }
        extra += ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return CommandResolver(searchPaths: path.map { ($0 as NSString).expandingTildeInPath } + extra)
    }

    /// Absolute path of the first executable regular file named `name`.
    public func resolve(_ name: String) -> String? {
        if name.contains("/") { return Self.isExecutableFile(name) ? name : nil }
        return searchPaths.lazy.map { $0 + "/" + name }.first(where: Self.isExecutableFile)
    }

    public func resolve(_ command: NativeCleanCommand) -> String? {
        command.executables.lazy.compactMap(resolve).first
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && access(path, X_OK) == 0
    }
}

public struct CommandResult: Sendable, Codable {
    public let command: String
    public let exitCode: Int32
    public let timedOut: Bool
    /// Tail of combined stdout/stderr.
    public let output: String

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

enum CacheCommandRunner {
    private static let outputLimit = 4_000

    /// Runs a command with stdin closed and a hard timeout; the executable's own directory and
    /// the resolver's search paths are put on PATH so `#!/usr/bin/env node` scripts work.
    static func run(executable: String, arguments: [String], timeout: Double, searchPaths: [String]) -> CommandResult {
        let display = ([(executable as NSString).lastPathComponent] + arguments).joined(separator: " ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var environment = ProcessInfo.processInfo.environment
        let systemPaths = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        environment["PATH"] = ([(executable as NSString).deletingLastPathComponent] + searchPaths + systemPaths).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["NO_COLOR"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return CommandResult(command: display, exitCode: -1, timedOut: false, output: "\(error)")
        }

        // Drain the pipe concurrently so a chatty command cannot block on a full buffer.
        let collected = LockedArray<Data>(repeating: Data(), count: 1)
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        Thread.detachNewThread {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                var data = collected[0]
                data.append(chunk)
                if data.count > outputLimit * 2 { data = data.suffix(outputLimit) }
                collected[0] = data
            }
            drained.signal()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        // A grandchild may keep the pipe open; do not wait for it forever.
        _ = drained.wait(timeout: .now() + 2)

        let text = String(decoding: collected[0].suffix(outputLimit), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(command: display, exitCode: process.terminationStatus, timedOut: timedOut, output: text)
    }
}

/// Dotted version found in a name: `17.0.1 (21A340)` → [17,0,1], `mac_arm-148.0.7778.97` → [148,0,7778,97],
/// `chromium-1228` → [1228], `v22.18.0` → [22,18,0]. Names without digits compare lowest.
struct VersionNumber: Comparable {
    let parts: [Int]

    init(_ name: String) {
        let scalars = Array(name)
        var runs: [[Int]] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index].isASCII, scalars[index].isNumber else {
                index += 1
                continue
            }
            var parts: [Int] = []
            var current = 0
            while index < scalars.count {
                let character = scalars[index]
                if character.isASCII, let digit = character.wholeNumberValue {
                    current = current &* 10 &+ digit
                } else if character == ".", index + 1 < scalars.count, scalars[index + 1].isASCII, scalars[index + 1].isNumber {
                    parts.append(current)
                    current = 0
                } else {
                    break
                }
                index += 1
            }
            parts.append(current)
            runs.append(parts)
        }
        // Prefer the first dotted run (skips model numbers like `iPhone15,2`), else the last plain number.
        parts = runs.first(where: { $0.count > 1 }) ?? runs.last ?? []
    }

    static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        for (left, right) in zip(lhs.parts, rhs.parts) where left != right {
            return left < right
        }
        return lhs.parts.count < rhs.parts.count
    }
}
