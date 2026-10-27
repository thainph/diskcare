import CoreServices
import Darwin
import Foundation

/// Directories reported changed by one FSEvents callback (already coalesced by `latency`).
public struct FSEventBatch: Sendable {
    /// Directories whose direct contents changed (no trailing slash, in the caller's path spelling).
    public let directories: Set<String>
    /// Directories whose whole subtree must be considered changed (events were coalesced or dropped).
    public let subtreesChanged: Set<String>
    /// A watched root itself was moved, deleted or recreated.
    public let rootChanged: Bool
    /// The replay of events since `sinceWhen` finished with this batch.
    public let historyDone: Bool
    public let lastEventID: FSEventStreamEventId

    public var isEmpty: Bool { directories.isEmpty && subtreesChanged.isEmpty }
}

/// Directory-level FSEvents stream (file events off) delivered on a private serial queue.
public final class FSEventsWatcher: @unchecked Sendable {
    public let paths: [String]
    public let latency: TimeInterval

    private let sinceWhen: FSEventStreamEventId
    private let handler: @Sendable (FSEventBatch) -> Void
    private let queue = DispatchQueue(label: "dev.diskcare.fsevents", qos: .utility)
    private static let queueKey = DispatchSpecificKey<Bool>()
    /// Real (symlink-resolved) root → root as given, e.g. /private/var/folders → /var/folders.
    private let aliases: [(real: String, given: String)]
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var latestEventID: FSEventStreamEventId

    /// - Parameter sinceWhen: replay changes after this event id (from a previous run); nil = only new changes.
    public init(
        paths: [String],
        sinceWhen: FSEventStreamEventId? = nil,
        latency: TimeInterval = 15,
        handler: @escaping @Sendable (FSEventBatch) -> Void
    ) {
        self.paths = paths.map(ScanOptions.normalize)
        self.latency = latency
        self.sinceWhen = sinceWhen ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
        self.handler = handler
        queue.setSpecific(key: Self.queueKey, value: true)
        latestEventID = sinceWhen ?? FSEventsGetCurrentEventId()
        aliases = self.paths.compactMap { path in
            guard let real = realpath(path, nil) else { return nil }
            defer { free(real) }
            let resolved = String(cString: real)
            return resolved == path ? nil : (resolved, path)
        }
    }

    deinit {
        stop()
    }

    /// Id of the newest event seen; persist it to replay changes on the next run.
    public var lastEventID: FSEventStreamEventId {
        lock.lock()
        defer { lock.unlock() }
        return latestEventID
    }

    public static var currentEventID: FSEventStreamEventId { FSEventsGetCurrentEventId() }

    /// Identifies the FSEvents database of the volume holding `path`; event ids from a
    /// previous run are only valid while it is unchanged.
    public static func eventDatabaseUUID(for path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard stream == nil else { return true }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            nil, Self.callback, &context, paths as CFArray, sinceWhen, latency, flags
        ) else { return false }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return false
        }
        stream = created
        return true
    }

    public func stop() {
        lock.lock()
        let current = stream
        stream = nil
        lock.unlock()
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
        // Invalidate does not wait for an in-flight callback; drain the queue before `self` can go away.
        if DispatchQueue.getSpecific(key: Self.queueKey) == nil { queue.sync {} }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, rawIDs in
        guard let info else { return }
        let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(rawPaths, to: NSArray.self)
        var events: [(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)] = []
        events.reserveCapacity(count)
        for index in 0..<count {
            guard let path = paths[index] as? String else { continue }
            events.append((path, rawFlags[index], rawIDs[index]))
        }
        watcher.deliver(events)
    }

    private func deliver(_ events: [(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)]) {
        var directories = Set<String>()
        var subtrees = Set<String>()
        var rootChanged = false
        var historyDone = false
        var maxID: FSEventStreamEventId = 0
        for event in events {
            maxID = max(maxID, event.id)
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                historyDone = true
                continue
            }
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                rootChanged = true
                continue
            }
            let path = translate(event.path)
            if event.flags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                subtrees.insert(path)
            } else {
                directories.insert(path)
            }
        }
        lock.lock()
        if maxID > latestEventID { latestEventID = maxID }
        let lastID = latestEventID
        lock.unlock()
        handler(FSEventBatch(
            directories: directories, subtreesChanged: subtrees,
            rootChanged: rootChanged, historyDone: historyDone, lastEventID: lastID
        ))
    }

    /// Strips the trailing slash and maps resolved paths back to the spelling of the watched root.
    private func translate(_ raw: String) -> String {
        var path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        for alias in aliases where path == alias.real || path.hasPrefix(alias.real + "/") {
            path = alias.given + path.dropFirst(alias.real.count)
            break
        }
        return path
    }
}
