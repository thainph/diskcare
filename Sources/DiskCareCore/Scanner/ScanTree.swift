/// Size counters for a directory (own files only, or a whole subtree once aggregated).
public struct Totals: Sendable, Codable, Equatable {
    /// Allocated bytes on disk; a hard-linked inode is counted once per scan.
    public var bytes: Int64 = 0
    public var files: Int64 = 0
    /// Part of `bytes` coming from files with more than one hard link (e.g. pnpm store
    /// links). Deleting the directory may not free this part.
    public var hardlinkedBytes: Int64 = 0
    /// Latest file modification time (seconds since 1970).
    public var latestModification: Int64 = 0

    public init() {}

    mutating func add(_ other: Totals) {
        bytes += other.bytes
        files += other.files
        hardlinkedBytes += other.hardlinkedBytes
        latestModification = max(latestModification, other.latestModification)
    }
}

/// A directory that keeps its own node in the tree. Directories inside an artifact
/// are not recorded individually; their totals roll up into the artifact node.
public struct DirectoryNode: Sendable {
    public let id: Int32
    public let parent: Int32
    public let path: String
    public let artifact: ArtifactKind?
    public var markers: ProjectMarkers
    /// Files directly inside (for artifacts: the whole subtree).
    public var own: Totals
    /// Whole subtree, filled by aggregation.
    public var total: Totals
    /// Latest modification of files outside artifacts/.git: a proxy for "last touched by a human".
    public var latestSourceModification: Int64
}

public struct ScanStats: Sendable, Codable, Equatable {
    public var directories: Int64 = 0
    public var files: Int64 = 0
    public var bytes: Int64 = 0
    public var errors: Int64 = 0
    public var skippedOtherDevice: Int64 = 0
    public var durationSeconds: Double = 0

    mutating func add(_ other: ScanStats) {
        directories += other.directories
        files += other.files
        errors += other.errors
        skippedOtherDevice += other.skippedOtherDevice
    }
}

/// Result of a filesystem scan; node ids are indexes, and a child always has a larger id than its parent.
public struct ScanTree: Sendable {
    public let roots: [String]
    public internal(set) var nodes: [DirectoryNode]
    public internal(set) var stats: ScanStats

    /// Sums every node into its ancestors. Relies on children having larger ids than parents.
    mutating func aggregate() {
        for index in nodes.indices {
            nodes[index].total = nodes[index].own
            nodes[index].latestSourceModification = nodes[index].artifact == nil ? nodes[index].own.latestModification : 0
        }
        for index in nodes.indices.reversed() {
            let node = nodes[index]
            guard node.parent >= 0 else { continue }
            let parent = Int(node.parent)
            nodes[parent].total.add(node.total)
            if node.artifact == nil {
                nodes[parent].latestSourceModification = max(nodes[parent].latestSourceModification, node.latestSourceModification)
            }
        }
        stats.bytes = nodes.filter { $0.parent < 0 }.reduce(0) { $0 + $1.total.bytes }
    }
}
