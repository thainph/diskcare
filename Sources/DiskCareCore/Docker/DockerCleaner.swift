import Foundation

public struct DockerCleanupOutcome: Sendable, Codable {
    public let item: DockerCleanupItem
    public let succeeded: Bool
    /// Exact figure from the API for build-cache pruning; the scan estimate for everything else.
    public let reclaimedBytes: Int64
    public let reclaimedIsEstimate: Bool
    /// Archive written before a volume was deleted.
    public let backupPath: String?
    public let error: String?
}

/// Executes a Docker cleanup plan through the Engine API. Each item is re-validated right before it
/// is touched, and nothing is ever force-removed: the daemon itself refuses in-use resources.
public struct DockerCleaner: Sendable {
    public let transport: any DockerTransport
    /// Required for items with `backup == true`; those fail (and are kept) without it.
    public let backup: DockerVolumeBackup?

    public init(transport: any DockerTransport, backup: DockerVolumeBackup?) {
        self.transport = transport
        self.backup = backup
    }

    /// Convenience for the local daemon, backing volumes up to `backupDirectory`.
    public init(socketPath: String, backupDirectory: URL = DockerVolumeBackup.defaultDirectory) {
        let transport = UnixSocketDockerTransport(socketPath: socketPath)
        self.init(transport: transport, backup: DockerVolumeBackup(transport: transport, directory: backupDirectory))
    }

    public func execute(_ plan: DockerCleanupPlan, progress: (@Sendable (DockerCleanupOutcome) -> Void)? = nil) -> [DockerCleanupOutcome] {
        plan.items.map { item in
            let outcome = execute(item)
            progress?(outcome)
            return outcome
        }
    }

    public func execute(_ item: DockerCleanupItem) -> DockerCleanupOutcome {
        var backupPath: String?
        do {
            switch item.action {
            case .removeContainer:
                try removeContainer(item.target)
            case .removeImage:
                try removeImage(item)
            case .pruneBuildCache:
                let pruned = try transport.call(
                    DockerRequest(.post, "/build/prune", query: [("all", "true")], timeout: 600), as: BuildPruneResponse.self
                )
                return DockerCleanupOutcome(
                    item: item, succeeded: true, reclaimedBytes: pruned.SpaceReclaimed ?? 0,
                    reclaimedIsEstimate: pruned.SpaceReclaimed == nil, backupPath: nil, error: nil
                )
            case .removeVolume:
                backupPath = try removeVolume(item)
            }
            return DockerCleanupOutcome(
                item: item, succeeded: true, reclaimedBytes: item.estimatedBytes ?? 0,
                reclaimedIsEstimate: true, backupPath: backupPath, error: nil
            )
        } catch {
            return DockerCleanupOutcome(
                item: item, succeeded: false, reclaimedBytes: 0, reclaimedIsEstimate: false, backupPath: backupPath, error: "\(error)"
            )
        }
    }

    // MARK: Containers

    func removeContainer(_ id: String) throws {
        guard let inspect = try transport.callIfExists(DockerRequest(.get, "/containers/\(id)/json"), as: ContainerStateResponse.self) else {
            throw DockerCleanupError.gone("container")
        }
        let state = inspect.State
        if state?.Running == true || state?.Paused == true || state?.Restarting == true
            || DockerReport.isActive(state: state?.Status ?? "") {
            throw DockerCleanupError.changed("container is \(state?.Status ?? "running") now")
        }
        // v=false keeps its anonymous volumes; they show up as unused volumes afterwards.
        try transport.call(DockerRequest(.delete, "/containers/\(id)", query: [("v", "false"), ("force", "false")]))
    }

    // MARK: Images

    func removeImage(_ item: DockerCleanupItem) throws {
        guard try transport.callIfExists(DockerRequest(.get, "/images/\(item.target)/json"), as: ImageInspectResponse.self) != nil else {
            throw DockerCleanupError.gone("image")
        }
        let users = try containers(filter: "ancestor", value: item.target)
        guard users.isEmpty else { throw DockerCleanupError.changed("image is used by \(Self.names(users))") }

        // An image with several tags cannot be removed by ID without force; untag each reference instead.
        if item.tags.count > 1 {
            for tag in item.tags {
                _ = try transport.callIfExistsRaw(DockerRequest(.delete, "/images/\(tag)", query: [("force", "false"), ("noprune", "false")]))
            }
            guard try transport.callIfExists(DockerRequest(.get, "/images/\(item.target)/json"), as: ImageInspectResponse.self) != nil else {
                return
            }
        }
        try transport.call(DockerRequest(.delete, "/images/\(item.target)", query: [("force", "false"), ("noprune", "false")]))
    }

    // MARK: Volumes

    /// Returns the backup archive path, if one was written.
    func removeVolume(_ item: DockerCleanupItem) throws -> String? {
        let name = item.target
        guard try transport.callIfExists(DockerRequest(.get, "/volumes/\(name)"), as: VolumeInspectResponse.self) != nil else {
            throw DockerCleanupError.gone("volume")
        }
        try ensureVolumeUnused(name)

        var archivePath: String?
        if item.backup {
            guard let backup else { throw DockerCleanupError.backupFailed("no backup location configured") }
            do {
                archivePath = try backup.backup(volume: name).path
            } catch {
                throw DockerCleanupError.backupFailed("\(error)")
            }
            // Something may have attached while the archive was being written.
            try ensureVolumeUnused(name)
        }
        do {
            try transport.call(DockerRequest(.delete, "/volumes/\(name)", query: [("force", "false")]))
        } catch {
            throw DockerCleanupError.deleteFailed(detail: "\(error)", backup: archivePath)
        }
        return archivePath
    }

    private func ensureVolumeUnused(_ name: String) throws {
        let users = try containers(filter: "volume", value: name)
        guard users.isEmpty else { throw DockerCleanupError.changed("volume is used by \(Self.names(users))") }
    }

    // MARK: Helpers

    private func containers(filter: String, value: String) throws -> [ContainerSummaryResponse] {
        try transport.call(
            DockerRequest(.get, "/containers/json", query: [("all", "1"), ("filters", DockerRequest.filters([filter: [value]]))]),
            as: [ContainerSummaryResponse].self
        )
    }

    private static func names(_ containers: [ContainerSummaryResponse]) -> String {
        containers.prefix(3).map { $0.Names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(($0.Id ?? "?").prefix(12)) }
            .joined(separator: ", ") + (containers.count > 3 ? " and \(containers.count - 3) more" : "")
    }
}

public enum DockerCleanupError: Error, Sendable, CustomStringConvertible {
    case gone(String)
    case changed(String)
    case backupFailed(String)
    case deleteFailed(detail: String, backup: String?)

    public var description: String {
        switch self {
        case .gone(let kind): "\(kind) no longer exists"
        case .changed(let detail): "skipped, \(detail)"
        case .backupFailed(let detail): "backup failed, volume kept: \(detail)"
        case .deleteFailed(let detail, let backup): "\(detail)\(backup.map { " (backup kept at \($0.abbreviatingHome))" } ?? "")"
        }
    }
}

extension DockerTransport {
    /// Like `call` but tolerates 404 (already removed); returns nil in that case.
    @discardableResult
    func callIfExistsRaw(_ request: DockerRequest) throws -> HTTPResponse? {
        do {
            return try call(request)
        } catch DockerClientError.http(status: 404, _) {
            return nil
        }
    }
}
