import Foundation

/// What the user asked to clean. Everything is opt-in; named volumes are backed up unless `skipBackup`.
public struct DockerCleanupSelection: Sendable, Codable {
    public var images = false
    public var buildCache = false
    public var containers = false
    /// Specific unused volumes by name.
    public var volumes: [String] = []
    /// All unused named volumes of these compose projects.
    public var projects: [String] = []
    public var anonymousVolumes = false
    /// Delete named volumes without exporting them first.
    public var skipBackup = false

    public init(
        images: Bool = false, buildCache: Bool = false, containers: Bool = false,
        volumes: [String] = [], projects: [String] = [], anonymousVolumes: Bool = false, skipBackup: Bool = false
    ) {
        self.images = images
        self.buildCache = buildCache
        self.containers = containers
        self.volumes = volumes
        self.projects = projects
        self.anonymousVolumes = anonymousVolumes
        self.skipBackup = skipBackup
    }

    public var isEmpty: Bool {
        !images && !buildCache && !containers && volumes.isEmpty && projects.isEmpty && !anonymousVolumes
    }
}

public enum DockerCleanupAction: String, Sendable, Codable {
    case removeContainer, removeImage, pruneBuildCache, removeVolume
}

public struct DockerCleanupItem: Sendable, Codable, Identifiable, Hashable {
    public var id: String { "\(action.rawValue):\(target)" }
    public let action: DockerCleanupAction
    /// Container ID, image ID, volume name, or "build-cache".
    public let target: String
    /// Human-readable name (container name, image tags, volume name).
    public let label: String
    /// From the scan; the API reports exact figures only for build-cache pruning.
    public let estimatedBytes: Int64?
    /// Image tags at scan time (removed one by one when there are several).
    public let tags: [String]
    public let composeProject: String?
    /// Volumes only: export to a `.tar.gz` before deleting, and abort the delete if that fails.
    public let backup: Bool
    /// Volumes only: anonymous (scratch) rather than named (may hold user data).
    public let isAnonymousVolume: Bool

    public init(
        action: DockerCleanupAction, target: String, label: String, estimatedBytes: Int64?,
        tags: [String] = [], composeProject: String? = nil, backup: Bool = false, isAnonymousVolume: Bool = false
    ) {
        self.action = action
        self.target = target
        self.label = label
        self.estimatedBytes = estimatedBytes
        self.tags = tags
        self.composeProject = composeProject
        self.backup = backup
        self.isAnonymousVolume = isAnonymousVolume
    }
}

public struct DockerCleanupPlan: Sendable, Codable {
    /// Ordered for execution: containers, images, build cache, volumes.
    public let items: [DockerCleanupItem]
    /// Requested volumes or projects that have nothing unused to remove, with a reason.
    public let skipped: [String: String]

    public var isEmpty: Bool { items.isEmpty }
    public var estimatedBytes: Int64 { items.reduce(0) { $0 + ($1.estimatedBytes ?? 0) } }
}

public enum DockerCleanupPlanner {
    public static let buildCacheTarget = "build-cache"

    /// Selects items from a fresh report. Only resources the report lists as unused are ever planned.
    public static func plan(_ report: DockerReport, selection: DockerCleanupSelection) -> DockerCleanupPlan {
        var items: [DockerCleanupItem] = []
        var skipped: [String: String] = [:]
        guard report.available else { return DockerCleanupPlan(items: [], skipped: [:]) }

        if selection.containers {
            items += report.stoppedContainers.map {
                DockerCleanupItem(
                    action: .removeContainer, target: $0.id, label: $0.name,
                    estimatedBytes: $0.bytes, composeProject: $0.composeProject
                )
            }
        }
        if selection.images {
            items += report.unusedImages.map {
                DockerCleanupItem(
                    action: .removeImage, target: $0.id, label: $0.isDangling ? "<dangling> \($0.shortID)" : $0.tags.joined(separator: ", "),
                    estimatedBytes: $0.uniqueBytes, tags: $0.tags
                )
            }
        }
        if selection.buildCache, report.buildCache.records > report.buildCache.inUse {
            items.append(DockerCleanupItem(
                action: .pruneBuildCache, target: buildCacheTarget,
                label: "\(report.buildCache.records - report.buildCache.inUse) unused build cache records",
                estimatedBytes: report.buildCache.reclaimableBytes
            ))
        }

        let unused = report.unusedVolumeGroups.flatMap(\.volumes)
        var chosen: [DockerVolumeEntry] = []
        func add(_ volume: DockerVolumeEntry) {
            if !chosen.contains(where: { $0.name == volume.name }) { chosen.append(volume) }
        }
        for name in selection.volumes {
            if let volume = unused.first(where: { $0.name == name }) { add(volume) } else { skipped[name] = "not found or still used by a container" }
        }
        for project in selection.projects {
            let matches = unused.filter { !$0.isAnonymous && $0.composeProject == project }
            if matches.isEmpty { skipped["project \(project)"] = "no unused named volumes" }
            matches.forEach(add)
        }
        if selection.anonymousVolumes { unused.filter(\.isAnonymous).forEach(add) }
        items += chosen.map {
            DockerCleanupItem(
                action: .removeVolume, target: $0.name, label: $0.name, estimatedBytes: $0.bytes,
                composeProject: $0.composeProject,
                // Anonymous volumes are scratch space; named ones may hold real data.
                backup: !$0.isAnonymous && !selection.skipBackup,
                isAnonymousVolume: $0.isAnonymous
            )
        }
        return DockerCleanupPlan(items: items, skipped: skipped)
    }
}
