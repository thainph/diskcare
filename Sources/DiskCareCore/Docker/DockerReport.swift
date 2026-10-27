import Foundation

public enum DockerCategory: String, Sendable, Codable, CaseIterable {
    case images, containers, volumes, buildCache

    public var title: String {
        switch self {
        case .images: "Images"
        case .containers: "Containers"
        case .volumes: "Local Volumes"
        case .buildCache: "Build Cache"
        }
    }
}

/// One row of `docker system df`.
public struct DockerCategorySummary: Sendable, Codable, Identifiable {
    public var id: DockerCategory { category }
    public let category: DockerCategory
    public let totalCount: Int
    public let activeCount: Int
    public let totalBytes: Int64
    public let reclaimableBytes: Int64
}

public struct DockerEngineInfo: Sendable, Codable {
    public let version: String?
    public let apiVersion: String?
    public let platform: String?
    public let os: String?
    public let arch: String?
}

public struct DockerImageEntry: Sendable, Codable, Identifiable {
    public let id: String
    /// Empty for dangling images.
    public let tags: [String]
    public let createdAt: Date?
    public let bytes: Int64
    /// Layers shared with other images; removing this image alone does not free them.
    public let sharedBytes: Int64
    public var uniqueBytes: Int64 { max(0, bytes - sharedBytes) }
    public var isDangling: Bool { tags.isEmpty }
    public var shortID: String { String(id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) }
}

public struct DockerContainerEntry: Sendable, Codable, Identifiable {
    public let id: String
    public let name: String
    public let image: String
    public let state: String
    public let status: String
    public let createdAt: Date?
    /// From `/containers/{id}/json`; nil if not inspected.
    public let finishedAt: Date?
    /// Writable layer size.
    public let bytes: Int64
    public let composeProject: String?
    public var shortID: String { String(id.prefix(12)) }
}

public struct DockerVolumeEntry: Sendable, Codable, Identifiable {
    public var id: String { name }
    public let name: String
    public let driver: String
    public let createdAt: Date?
    /// nil when the driver does not report a size.
    public let bytes: Int64?
    /// Containers (running or stopped) referencing the volume; nil if unknown.
    public let refCount: Int?
    public let composeProject: String?
    /// Anonymous volumes (64-hex names) are scratch space; named volumes may hold database or other user data.
    public let isAnonymous: Bool
    public var mayHoldData: Bool { !isAnonymous }
}

/// Unused volumes sharing a compose project (or the anonymous / no-project buckets).
public struct DockerVolumeGroup: Sendable, Codable, Identifiable {
    public var id: String { "\(isAnonymous ? "anonymous" : "named"):\(composeProject ?? "")" }
    public let composeProject: String?
    public let isAnonymous: Bool
    public let volumes: [DockerVolumeEntry]
    public var bytes: Int64 { volumes.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

public struct DockerBuildCacheSummary: Sendable, Codable {
    public let records: Int
    public let inUse: Int
    public let reclaimableBytes: Int64
    public let lastUsedAt: Date?
}

public struct DockerReport: Sendable, Codable {
    public let scannedAt: Date
    public let socketPath: String?
    public let available: Bool
    /// Why Docker could not be queried (daemon stopped, no socket, ...).
    public let error: String?
    public let engine: DockerEngineInfo?
    public let categories: [DockerCategorySummary]
    /// Images with no containers, largest first.
    public let unusedImages: [DockerImageEntry]
    /// Exited/created/dead containers, largest first.
    public let stoppedContainers: [DockerContainerEntry]
    /// Volumes with no referencing container: named groups by size, then the anonymous bucket.
    public let unusedVolumeGroups: [DockerVolumeGroup]
    public let buildCache: DockerBuildCacheSummary

    public var totalBytes: Int64 { categories.reduce(0) { $0 + $1.totalBytes } }
    public var reclaimableBytes: Int64 { categories.reduce(0) { $0 + $1.reclaimableBytes } }

    public func summary(_ category: DockerCategory) -> DockerCategorySummary? {
        categories.first { $0.category == category }
    }

    public static func unavailable(socketPath: String?, error: String, at date: Date = Date()) -> DockerReport {
        DockerReport(
            scannedAt: date, socketPath: socketPath, available: false, error: error, engine: nil,
            categories: [], unusedImages: [], stoppedContainers: [], unusedVolumeGroups: [],
            buildCache: DockerBuildCacheSummary(records: 0, inUse: 0, reclaimableBytes: 0, lastUsedAt: nil)
        )
    }
}

// MARK: - Building from API payloads

extension DockerReport {
    static let composeProjectLabel = "com.docker.compose.project"
    static let anonymousVolumeLabel = "com.docker.volume.anonymous"

    init(
        systemDF df: SystemDFResponse,
        version: DockerVersionResponse?,
        socketPath: String?,
        finishedAt: [String: Date] = [:],
        scannedAt: Date = Date()
    ) {
        let images = df.images.map { image in
            DockerImageEntry(
                id: image.Id ?? "",
                tags: (image.RepoTags ?? []).filter { $0 != "<none>:<none>" },
                createdAt: DockerDate.fromUnix(image.Created),
                bytes: max(0, image.Size ?? 0),
                sharedBytes: max(0, image.SharedSize ?? 0)
            )
        }
        let imageContainers = df.images.map { $0.Containers ?? -1 }

        let containers = df.containers.map { container in
            let id = container.Id ?? ""
            return DockerContainerEntry(
                id: id,
                name: container.Names?.first.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(id.prefix(12)),
                image: container.Image ?? "",
                state: container.State ?? "unknown",
                status: container.Status ?? "",
                createdAt: DockerDate.fromUnix(container.Created),
                finishedAt: finishedAt[id],
                bytes: max(0, container.SizeRw ?? 0),
                composeProject: container.Labels?[Self.composeProjectLabel]
            )
        }

        let volumes = df.volumes.map { volume in
            let name = volume.Name ?? ""
            let size = volume.UsageData?.Size
            let refCount = volume.UsageData?.RefCount
            return DockerVolumeEntry(
                name: name,
                driver: volume.Driver ?? "local",
                createdAt: DockerDate.parse(volume.CreatedAt),
                bytes: size.flatMap { $0 >= 0 ? $0 : nil },
                refCount: refCount.flatMap { $0 >= 0 ? $0 : nil },
                composeProject: volume.Labels?[Self.composeProjectLabel],
                isAnonymous: Self.isAnonymousVolume(name: name, labels: volume.Labels ?? [:])
            )
        }

        let cache = df.buildCache

        // Local fallbacks mirror the docker CLI's `system df` arithmetic.
        let imageUsed = zip(images, imageContainers).reduce(Int64(0)) { sum, pair in
            pair.1 > 0 ? sum + pair.0.uniqueBytes : sum
        }
        let imageTotal = df.LayersSize ?? images.reduce(0) { $0 + $1.uniqueBytes }
        let imageSummary = Self.summary(
            .images, usage: df.ImageUsage,
            count: images.count,
            active: imageContainers.filter { $0 > 0 }.count,
            total: imageTotal,
            reclaimable: max(0, imageTotal - imageUsed)
        )

        let running = containers.filter { Self.isActive(state: $0.state) }
        let containerTotal = containers.reduce(0) { $0 + $1.bytes }
        let containerSummary = Self.summary(
            .containers, usage: df.ContainerUsage,
            count: containers.count,
            active: running.count,
            total: containerTotal,
            reclaimable: containerTotal - running.reduce(0) { $0 + $1.bytes }
        )

        let unusedVolumes = volumes.filter { $0.refCount == 0 }
        let volumeSummary = Self.summary(
            .volumes, usage: df.VolumeUsage,
            count: volumes.count,
            active: volumes.filter { ($0.refCount ?? 0) > 0 }.count,
            total: volumes.reduce(0) { $0 + ($1.bytes ?? 0) },
            reclaimable: unusedVolumes.reduce(0) { $0 + ($1.bytes ?? 0) }
        )

        let privateCache = cache.filter { $0.Shared != true }
        let cacheReclaimable = privateCache.filter { $0.InUse != true }.reduce(Int64(0)) { $0 + max(0, $1.Size ?? 0) }
        let cacheSummary = Self.summary(
            .buildCache, usage: df.BuildCacheUsage,
            count: cache.count,
            active: cache.filter { $0.InUse == true }.count,
            total: privateCache.reduce(0) { $0 + max(0, $1.Size ?? 0) },
            reclaimable: cacheReclaimable
        )

        self.init(
            scannedAt: scannedAt,
            socketPath: socketPath,
            available: true,
            error: nil,
            engine: version.map {
                DockerEngineInfo(version: $0.Version, apiVersion: $0.ApiVersion, platform: $0.Platform?.Name, os: $0.Os, arch: $0.Arch)
            },
            categories: [imageSummary, containerSummary, volumeSummary, cacheSummary],
            unusedImages: zip(images, imageContainers).filter { $0.1 == 0 }.map(\.0).sorted { $0.bytes > $1.bytes },
            stoppedContainers: containers.filter { !Self.isActive(state: $0.state) }.sorted { $0.bytes > $1.bytes },
            unusedVolumeGroups: Self.group(unusedVolumes),
            buildCache: DockerBuildCacheSummary(
                records: cache.count,
                inUse: cache.filter { $0.InUse == true }.count,
                reclaimableBytes: cacheSummary.reclaimableBytes,
                lastUsedAt: cache.compactMap { DockerDate.parse($0.LastUsedAt) }.max()
            )
        )
    }

    /// Server-computed totals (API >= 1.52) win over local arithmetic when present.
    private static func summary<Item>(
        _ category: DockerCategory, usage: SystemDFResponse.Usage<Item>?,
        count: Int, active: Int, total: Int64, reclaimable: Int64
    ) -> DockerCategorySummary {
        DockerCategorySummary(
            category: category,
            totalCount: usage?.TotalCount ?? count,
            activeCount: usage?.ActiveCount ?? active,
            totalBytes: usage?.TotalSize ?? total,
            reclaimableBytes: usage?.Reclaimable ?? reclaimable
        )
    }

    static func isActive(state: String) -> Bool {
        ["running", "paused", "restarting"].contains(state.lowercased())
    }

    static func isAnonymousVolume(name: String, labels: [String: String]) -> Bool {
        if labels[anonymousVolumeLabel] != nil { return true }
        return name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Named volumes grouped by compose project (largest first, no-project bucket last), then anonymous ones.
    static func group(_ volumes: [DockerVolumeEntry]) -> [DockerVolumeGroup] {
        let bySize: (DockerVolumeEntry, DockerVolumeEntry) -> Bool = { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        let named = Dictionary(grouping: volumes.filter { !$0.isAnonymous }, by: \.composeProject)
            .map { DockerVolumeGroup(composeProject: $0.key, isAnonymous: false, volumes: $0.value.sorted(by: bySize)) }
            .sorted { lhs, rhs in
                if (lhs.composeProject == nil) != (rhs.composeProject == nil) { return lhs.composeProject != nil }
                return lhs.bytes != rhs.bytes ? lhs.bytes > rhs.bytes : (lhs.composeProject ?? "") < (rhs.composeProject ?? "")
            }
        let anonymous = volumes.filter(\.isAnonymous).sorted(by: bySize)
        return named + (anonymous.isEmpty ? [] : [DockerVolumeGroup(composeProject: nil, isAnonymous: true, volumes: anonymous)])
    }
}
