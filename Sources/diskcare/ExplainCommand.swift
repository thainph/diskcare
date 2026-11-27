import ArgumentParser
import DiskCareCore
import Foundation

struct Explain: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find what fills the disk outside your projects and known caches (report only).",
        discussion: """
        Reads the home folder except scan roots, catalogued caches, other apps' sandboxes, iCloud and
        mail. Desktop/Documents/Downloads/Pictures/Movies/Music are only read with Full Disk Access.
        Nothing is ever deleted.
        """
    )

    @Option(name: .long, help: "Project root already measured by `diskcare scan` (default: roots of the last recorded scan). Repeatable.")
    var root: [String] = []

    @Option(name: .long, help: "Hide directories smaller than this.")
    var minSize: String = "1GB"

    @Option(name: .long, help: "Rows to show.")
    var top: Int = 15

    @Option(name: .long, help: "History database path (for the last scan's roots and size).")
    var database: String = HistoryStore.defaultPath

    @Flag(name: .long, help: "Print the result as JSON.")
    var json = false

    func run() throws {
        let latest = FileManager.default.fileExists(atPath: database) ? try? HistoryStore(path: database).latestScan() : nil
        let roots = root.isEmpty ? (latest?.roots ?? []) : root.map(ScanOptions.normalize)
        let caches = CacheScanner.scan(CacheScanner.Options(definitions: CacheCatalog.definitions(scanRoots: roots)))
        let docker = DockerScanner.scan()

        var known: [KnownSource] = []
        if let latest, root.isEmpty { known.append(KnownSource(name: "projects (last scan)", bytes: latest.scannedBytes)) }
        known.append(KnownSource(name: "caches & app data", bytes: caches.totalBytes))
        if docker.available { known.append(KnownSource(name: "Docker", bytes: docker.totalBytes)) }

        let progress = ScanProgress()
        if !json { FileHandle.standardError.write(Data("Reading the home folder (this can take a minute)…\n".utf8)) }
        let explanation = DiskExplorer.explore(DiskExplorer.Options(
            scanRoots: roots, cachePaths: caches.entries.flatMap(\.paths), known: known,
            minimumBytes: try parseSize(minSize), limit: top, priority: .userInitiated, progress: progress
        ))
        if json {
            try printJSON(explanation)
            return
        }
        print(Self.render(explanation))
    }

    static func render(_ explanation: DiskExplanation) -> String {
        var lines: [String] = []
        if let volume = explanation.volume {
            let used = volume.volumeUsedBytes ?? (volume.totalBytes - volume.availableBytes)
            lines.append("Disk: \(ByteFormat.string(volume.availableBytes)) free of \(ByteFormat.string(volume.totalBytes))"
                + (volume.purgeableBytes > 0 ? " (+\(ByteFormat.string(volume.purgeableBytes)) purgeable)" : "")
                + ", \(ByteFormat.string(used)) used by this volume")
        }
        lines.append("\nKnown:")
        for source in explanation.known { lines.append("  \(source.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(ByteFormat.string(source.bytes))") }
        for source in explanation.outsideHome { lines.append("  \(source.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(ByteFormat.string(source.bytes))") }
        lines.append("  \("rest of home folder".padding(toLength: 24, withPad: " ", startingAt: 0)) \(ByteFormat.string(explanation.exploredBytes))")
        if let unaccounted = explanation.unaccountedBytes {
            lines.append("  \("not accounted for".padding(toLength: 24, withPad: " ", startingAt: 0)) \(ByteFormat.string(unaccounted))"
                + "  (system files, privacy-protected folders, VM disks in app containers, snapshots)")
        }

        lines.append("\nLargest folders outside projects and caches:")
        if explanation.unexplained.isEmpty { lines.append("  (none above the size limit)") }
        for row in explanation.unexplained {
            var note = row.isRemainder ? "  (other files)" : ""
            if row.containsProjects { note += "  ← has projects: add it as a scan root" }
            lines.append("  \(ByteFormat.string(row.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(row.path.abbreviatingHome)\(note)")
        }
        if let snapshots = explanation.localSnapshots, snapshots > 0 {
            lines.append("\n\(snapshots) local Time Machine snapshots hold deleted data until macOS purges them (`tmutil listlocalsnapshots /`).")
        }
        if !explanation.notReadWithoutFullDiskAccess.isEmpty {
            lines.append("\nNot read without Full Disk Access: " + explanation.notReadWithoutFullDiskAccess.map(\.abbreviatingHome).joined(separator: ", "))
        }
        if explanation.skippedDirectories > 0 { lines.append("\(explanation.skippedDirectories) folders could not be read and were skipped.") }
        lines.append(String(format: "\nRead in %.1fs. Report only: nothing was deleted.", explanation.durationSeconds))
        return lines.joined(separator: "\n")
    }
}
