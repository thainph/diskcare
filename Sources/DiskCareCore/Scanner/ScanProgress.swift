import Synchronization

/// Live counters a UI can poll while a scan runs. Lock-free; workers update once per directory.
public final class ScanProgress: Sendable {
    private let fileCount = Atomic<Int>(0)
    private let directoryCount = Atomic<Int>(0)
    private let gitDone = Atomic<Int>(0)
    private let gitTotal = Atomic<Int>(0)

    public init() {}

    public var files: Int { fileCount.load(ordering: .relaxed) }
    public var directories: Int { directoryCount.load(ordering: .relaxed) }
    /// Repositories inspected so far / to inspect in the current git phase.
    public var gitInspected: (done: Int, total: Int) {
        (gitDone.load(ordering: .relaxed), gitTotal.load(ordering: .relaxed))
    }

    func addDirectory(files: Int) {
        directoryCount.add(1, ordering: .relaxed)
        fileCount.add(files, ordering: .relaxed)
    }

    func startGit(total: Int) {
        gitDone.store(0, ordering: .relaxed)
        gitTotal.store(total, ordering: .relaxed)
    }

    func finishGitRepository() {
        gitDone.add(1, ordering: .relaxed)
    }

    /// Resets file/directory counters between phases.
    public func reset() {
        fileCount.store(0, ordering: .relaxed)
        directoryCount.store(0, ordering: .relaxed)
        gitDone.store(0, ordering: .relaxed)
        gitTotal.store(0, ordering: .relaxed)
    }
}
