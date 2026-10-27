import Darwin
import Foundation

public struct ScanOptions: Sendable {
    public var roots: [String]
    /// Absolute paths that are skipped together with their subtree.
    public var excludedPaths: Set<String>
    /// Directory listing is I/O bound, so more workers than cores still helps.
    public var workerCount: Int
    /// Do not cross into other volumes (network mounts, disk images, OrbStack NFS…).
    public var stayOnDevice: Bool

    public init(
        roots: [String],
        excludedPaths: Set<String> = [],
        workerCount: Int = max(8, ProcessInfo.processInfo.activeProcessorCount * 2),
        stayOnDevice: Bool = true
    ) {
        self.roots = roots.map(Self.normalize)
        self.excludedPaths = Set(excludedPaths.map(Self.normalize))
        self.workerCount = max(1, workerCount)
        self.stayOnDevice = stayOnDevice
    }

    public static func normalize(_ path: String) -> String {
        let standardized = (path as NSString).expandingTildeInPath
        let resolved = URL(fileURLWithPath: standardized).standardizedFileURL.path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }
}

/// Parallel directory walker built on getattrlistbulk(2).
public enum FileSystemScanner {
    /// Scans synchronously on dedicated threads (blocking I/O stays off the Swift concurrency pool).
    public static func scan(_ options: ScanOptions) -> ScanTree {
        let clock = ContinuousClock.now
        let queue = WorkQueue()
        let hardlinks = InodeSet()

        var seeds: [Job] = []
        for root in options.roots {
            var info = stat()
            guard lstat(root, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            seeds.append(Job(path: root, parent: -1, artifact: nil, rollup: -1, device: info.st_dev, needsNode: true))
        }
        queue.push(seeds)

        let workers = (0..<options.workerCount).map { _ in Worker(options: options, queue: queue, hardlinks: hardlinks) }
        let group = DispatchGroup()
        for worker in workers {
            group.enter()
            let thread = Thread {
                worker.run()
                group.leave()
            }
            thread.stackSize = 1 << 20
            thread.qualityOfService = .utility
            thread.start()
        }
        group.wait()

        var tree = merge(workers: workers, nodeCount: queue.assignedNodeCount, roots: options.roots)
        tree.stats.durationSeconds = (ContinuousClock.now - clock).seconds
        return tree
    }

    public static func scan(_ options: ScanOptions) async -> ScanTree {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: scan(options))
            }
        }
    }

    private static func merge(workers: [Worker], nodeCount: Int, roots: [String]) -> ScanTree {
        var slots = [DirectoryNode?](repeating: nil, count: nodeCount)
        var stats = ScanStats()
        for worker in workers {
            stats.add(worker.stats)
            for node in worker.nodes { slots[Int(node.id)] = node }
        }
        for worker in workers {
            for (target, totals) in worker.rollups { slots[Int(target)]?.own.add(totals) }
        }
        // A node whose directory could not be opened still exists (empty) so ids stay contiguous.
        let nodes = slots.enumerated().map { index, node in
            node ?? DirectoryNode(id: Int32(index), parent: -1, path: "", artifact: nil, markers: [], own: Totals(), total: Totals(), latestSourceModification: 0)
        }
        var tree = ScanTree(roots: roots, nodes: nodes, stats: stats)
        tree.aggregate()
        return tree
    }
}

struct Job {
    var path: String
    /// Node id of this directory, or -1 when it lives inside an artifact.
    var id: Int32 = -1
    var parent: Int32
    var artifact: ArtifactKind?
    /// Artifact node that collects this directory's totals, or -1.
    var rollup: Int32
    var device: dev_t
    var needsNode: Bool
}

/// LIFO job stack shared by workers. Depth-first order keeps the pending set small.
/// Node ids are assigned at push time, so a child's id is always greater than its parent's.
final class WorkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var stack: [Job] = []
    private var active = 0
    private var nextID: Int32 = 0

    var assignedNodeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return Int(nextID)
    }

    func push(_ jobs: [Job]) {
        condition.lock()
        enqueue(jobs)
        condition.broadcast()
        condition.unlock()
    }

    /// Blocks until a job is available; returns nil once all work is done.
    func next() -> Job? {
        condition.lock()
        defer { condition.unlock() }
        while stack.isEmpty && active > 0 {
            condition.wait()
        }
        guard let job = stack.popLast() else {
            condition.broadcast()
            return nil
        }
        active += 1
        return job
    }

    func complete(children: [Job]) {
        condition.lock()
        enqueue(children)
        active -= 1
        if children.count == 1 {
            condition.signal()
        } else if !children.isEmpty || active == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func enqueue(_ jobs: [Job]) {
        for var job in jobs {
            if job.needsNode {
                job.id = nextID
                nextID += 1
                if job.artifact != nil { job.rollup = job.id }
            }
            stack.append(job)
        }
    }
}

/// Inode ids of multi-link files already counted, sharded to limit lock contention.
final class InodeSet: @unchecked Sendable {
    private final class Shard {
        var lock = os_unfair_lock()
        var ids = Set<UInt64>()
    }

    private let shards = (0..<64).map { _ in Shard() }

    /// Returns true the first time an id is seen.
    func insert(_ id: UInt64) -> Bool {
        let shard = shards[Int(truncatingIfNeeded: (id &* 0x9E37_79B9_7F4A_7C15) >> 58)]
        os_unfair_lock_lock(&shard.lock)
        defer { os_unfair_lock_unlock(&shard.lock) }
        return shard.ids.insert(id).inserted
    }
}

/// Owns a reader buffer and per-thread results, merged once all workers finish.
final class Worker: @unchecked Sendable {
    private let options: ScanOptions
    private let queue: WorkQueue
    private let hardlinks: InodeSet
    private let reader = BulkDirectoryReader()

    private(set) var nodes: [DirectoryNode] = []
    private(set) var rollups: [Int32: Totals] = [:]
    private(set) var stats = ScanStats()

    init(options: ScanOptions, queue: WorkQueue, hardlinks: InodeSet) {
        self.options = options
        self.queue = queue
        self.hardlinks = hardlinks
    }

    func run() {
        while let job = queue.next() {
            queue.complete(children: process(job))
        }
    }

    private func process(_ job: Job) -> [Job] {
        var totals = Totals()
        var markers: ProjectMarkers = []
        var childNames: [String] = []

        let fd = open(job.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            stats.errors += 1
        } else {
            defer { close(fd) }
            var info = stat()
            if options.stayOnDevice, fstat(fd, &info) == 0, info.st_dev != job.device {
                stats.skippedOtherDevice += 1
            } else {
                stats.directories += 1
                let status = reader.forEachEntry(of: fd) { entry in
                    switch entry.type {
                    case .file:
                        markers.formUnion(ProjectMarkers.match(fileName: entry.name))
                        totals.files += 1
                        totals.latestModification = max(totals.latestModification, entry.modifiedAt)
                        if entry.linkCount > 1 {
                            if hardlinks.insert(entry.fileID) {
                                totals.bytes += entry.allocatedSize
                                totals.hardlinkedBytes += entry.allocatedSize
                            }
                        } else {
                            totals.bytes += entry.allocatedSize
                        }
                    case .directory:
                        let name = String(decoding: entry.name, as: UTF8.self)
                        if name == ".git" { markers.insert(.gitDirectory) }
                        childNames.append(name)
                    case .symlink, .other:
                        break
                    }
                }
                if status != 0 { stats.errors += 1 }
                stats.files += totals.files
            }
        }

        record(job, totals: totals, markers: markers)
        return children(of: job, names: childNames, markers: markers)
    }

    private func record(_ job: Job, totals: Totals, markers: ProjectMarkers) {
        if job.id >= 0 {
            nodes.append(DirectoryNode(
                id: job.id, parent: job.parent, path: job.path, artifact: job.artifact,
                markers: markers, own: totals, total: Totals(), latestSourceModification: 0
            ))
        } else if job.rollup >= 0 {
            rollups[job.rollup, default: Totals()].add(totals)
        }
    }

    private func children(of job: Job, names: [String], markers: ProjectMarkers) -> [Job] {
        let prefix = job.path == "/" ? "/" : job.path + "/"
        let vendored = job.rollup < 0 && ArtifactRules.isVendored(prefix)
        var jobs: [Job] = []
        jobs.reserveCapacity(names.count)
        for name in names {
            let path = prefix + name
            if !options.excludedPaths.isEmpty, options.excludedPaths.contains(path) { continue }
            if job.rollup >= 0 {
                jobs.append(Job(path: path, parent: -1, artifact: nil, rollup: job.rollup, device: job.device, needsNode: false))
            } else {
                let kind = ArtifactRules.classify(directoryName: name, parentMarkers: markers, vendored: vendored)
                jobs.append(Job(path: path, parent: job.id, artifact: kind, rollup: -1, device: job.device, needsNode: true))
            }
        }
        return jobs
    }
}
