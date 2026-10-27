import ArgumentParser
import DiskCareCore
import Foundation

@main
struct DiskCareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diskcare",
        abstract: "Find and clean disk space wasted by build artifacts, dependencies and stale worktrees.",
        version: DiskCareVersion.current,
        subcommands: [Scan.self, Clean.self, Caches.self, Docker.self, History.self, Watch.self, DoctorCommand.self],
        defaultSubcommand: Scan.self
    )
}

/// Options shared by commands that scan the filesystem.
struct ScanArguments: ParsableArguments {
    @Argument(help: "Directories to scan (default: home, excluding ~/Library and privacy-protected folders).")
    var paths: [String] = []

    @Option(name: .long, help: "Exclude a path (repeatable).")
    var exclude: [String] = []

    @Option(name: .long, help: "Number of scanner threads.")
    var workers: Int?

    var options: ScanOptions {
        let home = NSHomeDirectory()
        var excluded = Set(exclude)
        if paths.isEmpty {
            // Library is handled by dedicated cache scanners; the rest are TCC-protected and would prompt.
            for name in ["Library", ".Trash", "Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"] {
                excluded.insert(home + "/" + name)
            }
        }
        var options = ScanOptions(roots: paths.isEmpty ? [home] : paths, excludedPaths: excluded)
        if let workers { options.workerCount = workers }
        return options
    }
}

func parseSize(_ text: String) throws -> Int64 {
    guard let bytes = ByteFormat.parse(text) else { throw ValidationError("Invalid size: \(text)") }
    return bytes
}

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try encoder.encode(value))
    print()
}

struct Scan: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Scan directories and report reclaimable artifacts.")

    @OptionGroup var scan: ScanArguments

    @Option(name: .long, help: "Rows to show per table.")
    var top: Int = 20

    @Option(name: .long, help: "Hide artifacts smaller than this (e.g. 50MB).")
    var minSize: String = "50MB"

    @Flag(name: .long, help: "Skip git inspection (faster).")
    var noGit = false

    @Flag(name: .long, help: "Print the full report as JSON.")
    var json = false

    @Flag(name: .long, help: "Do not record this scan in the history database.")
    var noRecord = false

    @Option(name: .long, help: ArgumentHelp("History database path.", visibility: .hidden))
    var database: String = HistoryStore.defaultPath

    func run() throws {
        let minimum = try parseSize(minSize)
        let report = DiskAnalyzer.analyze(scan.options, inspectGit: !noGit)
        if !noRecord {
            do {
                try HistoryStore(path: database).record(report: report, freeBytes: Cleaner.availableCapacity(at: NSHomeDirectory()))
            } catch {
                FileHandle.standardError.write(Data("warning: could not record scan history: \(error)\n".utf8))
            }
        }
        if json {
            try printJSON(report)
        } else {
            ReportPrinter(report: report, top: top, minimumBytes: minimum).print()
        }
    }
}

struct Docker: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report Docker disk usage, clean unused resources, back up and restore volumes.",
        subcommands: [DockerReportCommand.self, DockerCleanCommand.self, DockerRestoreCommand.self],
        defaultSubcommand: DockerReportCommand.self
    )
}

struct DockerReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Report Docker disk usage and unused images, volumes and containers (read-only)."
    )

    @OptionGroup var docker: DockerArguments

    @Option(name: .long, help: "Rows to show per table.")
    var top: Int = 15

    @Flag(name: .long, help: "Print the full report as JSON.")
    var json = false

    func run() throws {
        let report = DockerScanner.scan(DockerScanner.Options(socketPath: docker.socket))
        if json {
            try printJSON(report)
        } else {
            DockerReportPrinter(report: report, top: top).print()
        }
    }
}
