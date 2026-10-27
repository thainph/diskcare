import ArgumentParser
import DiskCareCore
import Foundation

/// Options shared by the `docker` subcommands.
struct DockerArguments: ParsableArguments {
    @Option(name: .long, help: "Docker socket path (default: DOCKER_HOST, OrbStack, Docker Desktop, /var/run/docker.sock).")
    var socket: String?

    func resolvedSocket() throws -> String {
        try socket ?? DockerClient.resolveSocketPath()
    }
}

struct DockerCleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Remove unused Docker images, build cache, stopped containers and volumes (dry run unless --apply).",
        discussion: """
        Named volumes are exported to ~/DiskCareBackups/docker-volumes/<name>-<date>.tar.gz before deletion
        and are kept if the backup fails. Anonymous volumes are scratch space and are not backed up.

        Examples:
          diskcare docker clean --images --build-cache            # preview
          diskcare docker clean --images --build-cache --containers --apply
          diskcare docker clean --project shop --apply             # back up, then delete shop's unused volumes
          diskcare docker restore ~/DiskCareBackups/docker-volumes/shop_pgdata-20260101-120000.tar.gz
        """
    )

    @OptionGroup var docker: DockerArguments

    @Flag(name: .long, help: "Remove images not used by any container (tagged and dangling).")
    var images = false

    @Flag(name: .long, help: "Prune all unused build cache.")
    var buildCache = false

    @Flag(name: .long, help: "Remove stopped (exited/created/dead) containers.")
    var containers = false

    @Option(name: .long, help: "Remove this unused volume (repeatable).")
    var volume: [String] = []

    @Option(name: .long, help: "Remove all unused named volumes of this compose project (repeatable).")
    var project: [String] = []

    @Flag(name: .long, help: "Remove unused anonymous volumes.")
    var anonymousVolumes = false

    @Flag(name: .long, help: "Delete named volumes without backing them up first (data is lost for good).")
    var noBackup = false

    @Option(name: .long, help: "Backup directory for named volumes.")
    var backupDir: String?

    @Flag(name: .long, help: "Actually clean. Without it, only the plan is printed.")
    var apply = false

    @Flag(name: [.short, .long], help: "Do not ask for confirmation.")
    var yes = false

    @Flag(name: .long, help: "Print the plan (and outcomes) as JSON.")
    var json = false

    var selection: DockerCleanupSelection {
        DockerCleanupSelection(
            images: images, buildCache: buildCache, containers: containers, volumes: volume,
            projects: project, anonymousVolumes: anonymousVolumes, skipBackup: noBackup
        )
    }

    var backupDirectory: URL {
        backupDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) } ?? DockerVolumeBackup.defaultDirectory
    }

    func validate() throws {
        if selection.isEmpty {
            throw ValidationError("Choose what to clean: --images, --build-cache, --containers, --volume, --project or --anonymous-volumes.")
        }
    }

    func run() throws {
        let socket = try docker.resolvedSocket()
        let report = DockerScanner.scan(DockerScanner.Options(socketPath: socket))
        guard report.available else {
            print("Docker unavailable: \(report.error ?? "unknown error")")
            throw ExitCode(1)
        }
        let plan = DockerCleanupPlanner.plan(report, selection: selection)

        if json && !apply {
            try printJSON(plan)
            return
        }
        printPlan(plan)
        guard apply, !plan.isEmpty else {
            if !plan.isEmpty { print("\nDry run. Re-run with --apply to clean.") }
            return
        }
        guard yes || confirm(plan) else {
            print("Aborted.")
            return
        }

        let cleaner = DockerCleaner(socketPath: socket, backupDirectory: backupDirectory)
        let quiet = json
        let outcomes = cleaner.execute(plan) { outcome in
            guard !quiet else { return }
            let status = outcome.succeeded ? "ok" : "FAILED"
            var line = "  \(status): \(Self.verb(outcome.item.action)) \(outcome.item.label)"
            if let path = outcome.backupPath { line += " (backup: \(path.abbreviatingHome))" }
            if let error = outcome.error { line += " – \(error)" }
            print(line)
        }
        if json {
            try printJSON(outcomes)
        } else {
            let failed = outcomes.filter { !$0.succeeded }
            let reclaimed = outcomes.reduce(Int64(0)) { $0 + $1.reclaimedBytes }
            let estimated = outcomes.contains { $0.succeeded && $0.reclaimedIsEstimate }
            print("\nCleaned \(outcomes.count - failed.count)/\(outcomes.count) items, \(estimated ? "~" : "")\(ByteFormat.string(reclaimed)) reclaimed.")
        }
        if outcomes.contains(where: { !$0.succeeded }) { throw ExitCode(1) }
    }

    private func printPlan(_ plan: DockerCleanupPlan) {
        for (target, reason) in plan.skipped.sorted(by: { $0.key < $1.key }) {
            print("Skipping \(target): \(reason)")
        }
        guard !plan.isEmpty else {
            print("Nothing to clean.")
            return
        }
        print("Docker cleanup plan: \(plan.items.count) items, ~\(ByteFormat.string(plan.estimatedBytes))")
        table(
            headers: ["SIZE", "ACTION", "BACKUP", "PROJECT", "TARGET"],
            rows: plan.items.map {
                [
                    $0.estimatedBytes.map(ByteFormat.string) ?? "?",
                    Self.verb($0.action),
                    $0.action != .removeVolume ? "-" : ($0.backup ? "yes" : ($0.isAnonymousVolume ? "anon" : "NO")),
                    $0.composeProject ?? "-",
                    $0.label,
                ]
            },
            rightAligned: [0]
        )
        if plan.items.contains(where: \.backup) {
            print("Named volumes are archived to \(backupDirectory.path.abbreviatingHome)/ first and kept if the backup fails.")
        }
        let unprotected = plan.items.filter { $0.action == .removeVolume && !$0.backup && !$0.isAnonymousVolume }
        if !unprotected.isEmpty {
            print("WARNING: \(unprotected.count) named volume(s) will be deleted WITHOUT backup (--no-backup).")
        }
    }

    private func confirm(_ plan: DockerCleanupPlan) -> Bool {
        print("\nPermanently remove \(plan.items.count) Docker items (~\(ByteFormat.string(plan.estimatedBytes)))? [y/N] ", terminator: "")
        guard let answer = readLine()?.lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    static func verb(_ action: DockerCleanupAction) -> String {
        switch action {
        case .removeContainer: "rm container"
        case .removeImage: "rm image"
        case .pruneBuildCache: "prune cache"
        case .removeVolume: "rm volume"
        }
    }
}

struct DockerRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Restore a volume archive written by `diskcare docker clean`."
    )

    @OptionGroup var docker: DockerArguments

    @Argument(help: "Path to a <volume>-<date>.tar.gz archive.")
    var archive: String

    @Option(name: .long, help: "Target volume (default: the original volume name recorded with the archive). Created if missing.")
    var volume: String?

    @Flag(name: .long, help: "Extract into an existing volume even if it already contains files.")
    var allowNonEmpty = false

    func run() throws {
        let url = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath)
        guard let name = volume ?? DockerVolumeBackup.metadata(for: url)?.volume else {
            throw ValidationError("No metadata next to the archive; pass --volume NAME.")
        }
        let transport = UnixSocketDockerTransport(socketPath: try docker.resolvedSocket())
        try DockerVolumeBackup(transport: transport, directory: url.deletingLastPathComponent())
            .restore(archive: url, into: name, allowNonEmpty: allowNonEmpty)
        print("Restored \(url.path.abbreviatingHome) into volume \(name).")
    }
}
