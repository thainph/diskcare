import ArgumentParser
import DiskCareCore
import Foundation

@main
struct DiskCareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diskcare",
        abstract: "Find disk space wasted by build artifacts, dependencies and stale worktrees.",
        subcommands: [Scan.self, Docker.self],
        defaultSubcommand: Scan.self
    )
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan directories and report reclaimable artifacts.")

    @Argument(help: "Directories to scan (default: home, excluding ~/Library and privacy-protected folders).")
    var paths: [String] = []

    @Option(name: .long, help: "Exclude a path (repeatable).")
    var exclude: [String] = []

    @Option(name: .long, help: "Rows to show per table.")
    var top: Int = 20

    @Option(name: .long, help: "Hide artifacts smaller than this (e.g. 50MB).")
    var minSize: String = "50MB"

    @Option(name: .long, help: "Number of scanner threads.")
    var workers: Int?

    @Flag(name: .long, help: "Skip git inspection (faster).")
    var noGit = false

    @Flag(name: .long, help: "Print the full report as JSON.")
    var json = false

    func run() throws {
        let home = NSHomeDirectory()
        let roots = paths.isEmpty ? [home] : paths
        var excluded = Set(exclude)
        if paths.isEmpty {
            // Library is handled by dedicated cache scanners; the rest are TCC-protected and would prompt.
            for name in ["Library", ".Trash", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] {
                excluded.insert(home + "/" + name)
            }
        }
        guard let minimum = ByteFormat.parse(minSize) else {
            throw ValidationError("Invalid --min-size: \(minSize)")
        }

        var options = ScanOptions(roots: roots, excludedPaths: excluded)
        if let workers { options.workerCount = workers }
        let report = DiskAnalyzer.analyze(options, inspectGit: !noGit)

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(report))
            print()
        } else {
            ReportPrinter(report: report, top: top, minimumBytes: minimum).print()
        }
    }
}

struct Docker: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Report Docker disk usage and unused images, volumes and containers (read-only).")

    @Option(name: .long, help: "Docker socket path (default: DOCKER_HOST, OrbStack, Docker Desktop, /var/run/docker.sock).")
    var socket: String?

    @Option(name: .long, help: "Rows to show per table.")
    var top: Int = 15

    @Flag(name: .long, help: "Print the full report as JSON.")
    var json = false

    func run() throws {
        let report = DockerScanner.scan(DockerScanner.Options(socketPath: socket))
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            FileHandle.standardOutput.write(try encoder.encode(report))
            print()
        } else {
            DockerReportPrinter(report: report, top: top).print()
        }
    }
}
