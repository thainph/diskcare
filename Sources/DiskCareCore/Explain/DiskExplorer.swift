import Darwin
import Foundation

/// A large directory that no scan root or catalogued cache accounts for.
public struct UnexplainedDirectory: Sendable, Codable, Equatable {
    public let path: String
    public let bytes: Int64
    /// Holds a git repository near the top: worth adding as a scan root.
    public let containsProjects: Bool
    /// The bytes of a parent not covered by its listed children ("other files in ~/x").
    public let isRemainder: Bool
}

/// A known consumer of space, for the "where did it go" breakdown.
public struct KnownSource: Sendable, Codable, Equatable {
    public let name: String
    public let bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

/// Answer to "the disk is full, but where?". Report only: nothing here is ever cleaned.
public struct DiskExplanation: Sendable, Codable {
    public let exploredAt: Date
    public let durationSeconds: Double
    public let volume: VolumeSpace?
    public let known: [KnownSource]
    /// Largest unexplained directories in the home folder, largest first.
    public let unexplained: [UnexplainedDirectory]
    /// Everything read in the home folder outside roots and caches.
    public let exploredBytes: Int64
    /// Directories that could not be read (permissions) and were skipped.
    public let skippedDirectories: Int64
    /// Folders left out because only Full Disk Access may read them.
    public let notReadWithoutFullDiskAccess: [String]
    /// `/Applications`, Homebrew… measured as a whole.
    public let outsideHome: [KnownSource]
    public let localSnapshots: Int?
    public let cancelled: Bool

    public var knownBytes: Int64 { known.reduce(0) { $0 + $1.bytes } }

    /// Used space none of the above accounts for: system files, other users, privacy-protected
    /// folders, VM disk images inside app containers, local snapshots.
    public var unaccountedBytes: Int64? {
        guard let used = volume?.volumeUsedBytes else { return nil }
        return max(0, used - knownBytes - exploredBytes - outsideHome.reduce(0) { $0 + $1.bytes })
    }
}

public enum DiskExplorer {
    public struct Options: Sendable {
        public var home: String
        /// Project roots: already measured by the main scan.
        public var scanRoots: [String]
        /// Cache locations: already measured by the cache scan.
        public var cachePaths: [String]
        public var known: [KnownSource]
        /// nil = detect.
        public var fullDiskAccess: Bool?
        public var minimumBytes: Int64
        public var limit: Int
        /// Measure `/Applications` and Homebrew prefixes.
        public var measureOutsideHome: Bool
        public var countSnapshots: Bool
        public var priority: ScanPriority
        public var progress: ScanProgress?
        public var runCommand: CommandRunner

        public init(
            home: String = NSHomeDirectory(), scanRoots: [String] = [], cachePaths: [String] = [], known: [KnownSource] = [],
            fullDiskAccess: Bool? = nil, minimumBytes: Int64 = 1_000_000_000, limit: Int = 15,
            measureOutsideHome: Bool = true, countSnapshots: Bool = true,
            priority: ScanPriority = .background, progress: ScanProgress? = nil,
            runCommand: @escaping CommandRunner = ProcessRunner.run
        ) {
            self.home = home
            self.scanRoots = scanRoots
            self.cachePaths = cachePaths
            self.known = known
            self.fullDiskAccess = fullDiskAccess
            self.minimumBytes = minimumBytes
            self.limit = limit
            self.measureOutsideHome = measureOutsideHome
            self.countSnapshots = countSnapshots
            self.priority = priority
            self.progress = progress
            self.runCommand = runCommand
        }
    }

    /// Never read: other apps' sandboxes and synced/private stores (permission prompts, iCloud downloads).
    public static let alwaysExcluded = [
        "Library/CloudStorage", "Library/Mobile Documents", "OrbStack", ".Trash", "Library/Containers",
        "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Application Support/AddressBook",
        "Library/Application Support/MobileSync", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/Knowledge", "Library/Safari", "Library/Photos",
    ]

    /// Read only with Full Disk Access; without it macOS would ask for each.
    public static let privacyFolders = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music"]

    public static func explore(_ options: Options) -> DiskExplanation {
        let clock = ContinuousClock.now
        let home = ScanOptions.normalize(options.home)
        let fullDiskAccess = options.fullDiskAccess ?? hasFullDiskAccess(home: home)
        var excluded = Set(alwaysExcluded.map { home + "/" + $0 })
        // `com.apple.*` folders in Application Support are guarded like the ones above.
        let support = home + "/Library/Application Support"
        for name in (try? FileManager.default.contentsOfDirectory(atPath: support)) ?? [] where name.hasPrefix("com.apple.") {
            excluded.insert(support + "/" + name)
        }
        let withheld = fullDiskAccess ? [] : privacyFolders.map { home + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
        excluded.formUnion(withheld)
        excluded.formUnion(options.scanRoots.map(ScanOptions.normalize))
        excluded.formUnion(options.cachePaths.map(ScanOptions.normalize))

        let tree = FileSystemScanner.scan(ScanOptions(
            roots: [home], excludedPaths: excluded, stayOnDevice: true, priority: options.priority, progress: options.progress
        ))
        let unexplained = largest(in: tree, home: home, minimumBytes: options.minimumBytes, limit: options.limit)

        var outside: [KnownSource] = []
        if options.measureOutsideHome {
            for path in ["/Applications", "/opt/homebrew", "/usr/local"] where FileManager.default.fileExists(atPath: path) {
                guard options.progress?.isCancelled != true else { break }
                let bytes = FileSystemScanner.scan(ScanOptions(roots: [path], stayOnDevice: true, priority: options.priority, progress: options.progress)).stats.bytes
                outside.append(KnownSource(name: path, bytes: bytes))
            }
        }
        let snapshots = options.countSnapshots
            ? options.runCommand("/usr/bin/tmutil", ["listlocalsnapshots", "/"], 10).map { output in
                output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
            }
            : nil
        return DiskExplanation(
            exploredAt: Date(), durationSeconds: (ContinuousClock.now - clock).seconds,
            volume: VolumeSpace.measure(at: home), known: options.known, unexplained: unexplained,
            exploredBytes: tree.stats.bytes, skippedDirectories: tree.stats.errors,
            notReadWithoutFullDiskAccess: withheld, outsideHome: outside, localSnapshots: snapshots,
            cancelled: options.progress?.isCancelled == true
        )
    }

    /// Runs on its own thread with the options' priority (QoS and throttled I/O).
    public static func explore(_ options: Options) async -> DiskExplanation {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                options.priority.applyToCurrentThread()
                continuation.resume(returning: explore(options))
            }
        }
    }

    /// Directories one and two levels below home of at least `minimumBytes`. A big top-level folder
    /// whose listed children do not cover it also gets a "remainder" row.
    static func largest(in tree: ScanTree, home: String, minimumBytes: Int64, limit: Int) -> [UnexplainedDirectory] {
        guard let rootIndex = tree.nodes.firstIndex(where: { $0.parent < 0 && $0.path == home }) else { return [] }
        let rootID = tree.nodes[rootIndex].id
        var children: [Int32: [DirectoryNode]] = [:]
        for node in tree.nodes where node.parent >= 0 {
            children[node.parent, default: []].append(node)
        }
        var rows: [UnexplainedDirectory] = []
        for top in children[rootID] ?? [] where top.total.bytes >= minimumBytes {
            let big = (children[top.id] ?? []).filter { $0.total.bytes >= minimumBytes }
            for child in big {
                rows.append(UnexplainedDirectory(path: child.path, bytes: child.total.bytes, containsProjects: containsProjects(child, children), isRemainder: false))
            }
            let rest = top.total.bytes - big.reduce(0) { $0 + $1.total.bytes }
            if rest >= minimumBytes {
                rows.append(UnexplainedDirectory(path: top.path, bytes: rest, containsProjects: containsProjects(top, children), isRemainder: !big.isEmpty))
            }
        }
        return Array(rows.sorted { $0.bytes > $1.bytes }.prefix(limit))
    }

    /// A git repository in the directory or its children. Manifests alone are not enough: tool
    /// installs (editor extensions, node versions) are full of `package.json`.
    static func containsProjects(_ node: DirectoryNode, _ children: [Int32: [DirectoryNode]]) -> Bool {
        if !node.markers.isDisjoint(with: .anyGit) { return true }
        return (children[node.id] ?? []).contains { !$0.markers.isDisjoint(with: .anyGit) }
    }

    /// Files only Full Disk Access can open; without it `open` fails quietly (no prompt). Several,
    /// because which ones exist depends on the macOS version and the apps in use.
    static func fullDiskAccessProbes(home: String) -> [String] {
        [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Safari/CloudTabs.db",
            home + "/Library/Mail",
        ]
    }

    public static func hasFullDiskAccess(home: String = NSHomeDirectory()) -> Bool {
        fullDiskAccessProbes(home: home).contains { path in
            let descriptor = open(path, O_RDONLY | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            close(descriptor)
            return true
        }
    }
}

/// When to suggest (or run) the explorer: free space dropped a lot and the known sources do not
/// explain most of it.
public struct ExploreTrigger: Sendable, Codable, Equatable {
    /// Free space and known bytes at the last exploration.
    public var availableBytes: Int64
    public var knownBytes: Int64

    public init(availableBytes: Int64, knownBytes: Int64) {
        self.availableBytes = availableBytes
        self.knownBytes = knownBytes
    }

    /// `max(10 GB, 2%)` of the volume.
    public static func minimumDrop(totalBytes: Int64) -> Int64 {
        max(10_000_000_000, totalBytes / 50)
    }

    public func shouldExplore(availableBytes now: Int64, knownBytes known: Int64, totalBytes: Int64) -> Bool {
        let drop = availableBytes - now
        guard drop >= Self.minimumDrop(totalBytes: totalBytes) else { return false }
        let explained = known - knownBytes
        return explained * 2 < drop
    }
}
