import CoreServices
import Foundation

/// Watches scanned roots with FSEvents and re-measures only the artifacts that changed,
/// so fast growth (e.g. a Rust `target/` filling the disk) is reported within minutes.
///
/// Callbacks run on a private background queue; hop to the main actor for UI work.
public final class GrowthWatcher: @unchecked Sendable {
    public struct Configuration: Sendable {
        /// FSEvents coalescing delay.
        public var latency: TimeInterval = 15
        /// Re-measure once an artifact has been quiet for this long…
        public var settleSeconds: TimeInterval = 30
        /// …but at least this often while it keeps changing (a long `cargo build`).
        public var maxDelaySeconds: TimeInterval = 300
        /// Alert when an artifact grows past this size.
        public var sizeThresholdBytes: Int64 = 20_000_000_000
        /// Alert when an artifact grows by this much within `windowSeconds`.
        public var windowGrowthBytes: Int64 = 5_000_000_000
        public var windowSeconds: TimeInterval = 3_600
        /// Minimum time between two alerts of the same kind for one artifact.
        public var alertCooldownSeconds: TimeInterval = 3_600
        /// Track artifacts created after the last full scan (a fresh `target/`, `node_modules`…).
        public var discoverNewArtifacts = true
        /// Replay changes since the previous run (event id kept in the history store).
        public var replayFromLastRun = true

        public init() {}
    }

    public struct Measurement: Sendable, Codable, Equatable {
        public let path: String
        public let kind: ArtifactKind
        public let bytes: Int64
        /// Size at the previous measurement (or the last full scan).
        public let previousBytes: Int64
        /// Size in the last full scan; 0 for artifacts discovered since.
        public let baselineBytes: Int64
        public let measuredAt: Date
    }

    public enum AlertReason: Sendable, Equatable {
        /// Grew past `GrowthWatcher.Configuration.sizeThresholdBytes`.
        case crossedSize(threshold: Int64)
        /// Grew by `bytes` within `window` seconds (rate-extrapolated when samples are sparse).
        case fastGrowth(bytes: Int64, window: TimeInterval)
    }

    public struct Alert: Sendable, Equatable {
        public let measurement: Measurement
        public let reason: AlertReason

        public var title: String {
            "\(URL(fileURLWithPath: measurement.path).lastPathComponent) is growing fast"
        }

        public var message: String {
            let name = measurement.path.abbreviatingHome
            switch reason {
            case .crossedSize(let threshold):
                return "\(name) is now \(ByteFormat.string(measurement.bytes)) (over \(ByteFormat.string(threshold)))."
            case .fastGrowth(let bytes, let window):
                let minutes = Int((window / 60).rounded())
                let period = minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes) min"
                return "\(name) grew \(ByteFormat.string(bytes)) in the last \(period), now \(ByteFormat.string(measurement.bytes))."
            }
        }
    }

    private struct Tracked {
        let kind: ArtifactKind
        var baseline: Int64
        var current: Int64
        var samples: [(date: Date, bytes: Int64)]
        var lastAlert: [String: Date] = [:]
    }

    public let roots: [String]
    public let configuration: Configuration
    /// Subtrees ignored like in the scan (e.g. ~/Library when watching home).
    public let excludedPaths: Set<String>

    private let history: HistoryStore?
    private let onMeasure: @Sendable ([Measurement]) -> Void
    private let onAlert: @Sendable (Alert) -> Void
    private let queue = DispatchQueue(label: "dev.diskcare.growth-watcher", qos: .utility)
    private let measureQueue = DispatchQueue(label: "dev.diskcare.growth-measure", qos: .utility)

    // State below is only touched on `queue`.
    private var tracked: [String: Tracked] = [:]
    private var pending = Set<String>()
    private var pendingSince: Date?
    private var settleItem: DispatchWorkItem?
    private var measuring = false
    private var lastEventSave = Date.distantPast
    private var watcher: FSEventsWatcher?

    private static let eventIDKey = "growthWatcher.lastEventID"
    private static let eventDatabaseKey = "growthWatcher.eventDatabaseUUID"

    /// - Parameters:
    ///   - report: last full scan; its roots are watched and its artifacts are the baseline.
    ///   - excludedPaths: same exclusions as the scan; changes below them are ignored.
    ///   - history: stores the FSEvents id between runs (optional).
    ///   - onMeasure: every batch of re-measured artifacts.
    ///   - onAlert: an artifact crossed the size threshold or grew too fast.
    public init(
        report: ScanReport,
        configuration: Configuration = Configuration(),
        excludedPaths: Set<String> = [],
        history: HistoryStore? = nil,
        onMeasure: @escaping @Sendable ([Measurement]) -> Void = { _ in },
        onAlert: @escaping @Sendable (Alert) -> Void
    ) {
        roots = report.roots
        self.configuration = configuration
        self.excludedPaths = Set(excludedPaths.map(ScanOptions.normalize))
        self.history = history
        self.onMeasure = onMeasure
        self.onAlert = onAlert
        tracked = Self.trackedArtifacts(of: report)
    }

    deinit {
        watcher?.stop()
    }

    /// Number of artifacts currently tracked.
    public var trackedCount: Int { queue.sync { tracked.count } }

    @discardableResult
    public func start() -> Bool {
        queue.sync {
            guard watcher == nil else { return true }
            let since = configuration.replayFromLastRun ? storedEventID() : nil
            let watcher = FSEventsWatcher(paths: roots, sinceWhen: since, latency: configuration.latency) { [weak self] batch in
                guard let self else { return }
                queue.async { self.handle(batch) }
            }
            guard watcher.start() else { return false }
            self.watcher = watcher
            return true
        }
    }

    public func stop() {
        let current = queue.sync { () -> FSEventsWatcher? in
            settleItem?.cancel()
            settleItem = nil
            pending.removeAll()
            defer { watcher = nil }
            return watcher
        }
        current?.stop()
        if let current { saveEventID(current.lastEventID) }
    }

    /// Resets baselines after a new full scan (roots stay those given at init).
    public func update(report: ScanReport) {
        let fresh = Self.trackedArtifacts(of: report)
        queue.async {
            var merged = fresh
            for (path, old) in self.tracked {
                // Keep recent samples and alert cooldowns so a rescan does not re-alert.
                guard var entry = merged[path] else { continue }
                entry.samples = old.samples + entry.samples
                entry.lastAlert = old.lastAlert
                merged[path] = entry
            }
            self.tracked = merged
        }
    }

    private static func trackedArtifacts(of report: ScanReport) -> [String: Tracked] {
        var result: [String: Tracked] = [:]
        for artifact in report.artifacts {
            result[artifact.path] = Tracked(
                kind: artifact.kind, baseline: artifact.totals.bytes, current: artifact.totals.bytes,
                samples: [(report.scannedAt, artifact.totals.bytes)]
            )
        }
        return result
    }

    // MARK: Event handling (on `queue`)

    private func handle(_ batch: FSEventBatch) {
        for directory in batch.directories {
            if let artifact = locate(directory) { pending.insert(artifact) }
        }
        for directory in batch.subtreesChanged {
            if let artifact = locate(directory) { pending.insert(artifact) }
            let prefix = directory == "/" ? "/" : directory + "/"
            for path in tracked.keys where path.hasPrefix(prefix) { pending.insert(path) }
        }
        if batch.historyDone || Date().timeIntervalSince(lastEventSave) > 60 {
            lastEventSave = Date()
            saveEventID(batch.lastEventID)
        }
        guard !pending.isEmpty else { return }
        if pendingSince == nil { pendingSince = Date() }
        scheduleMeasurement()
    }

    private func scheduleMeasurement() {
        settleItem?.cancel()
        let waited = pendingSince.map { Date().timeIntervalSince($0) } ?? 0
        let delay = max(0, min(configuration.settleSeconds, configuration.maxDelaySeconds - waited))
        let item = DispatchWorkItem { [weak self] in self?.measurePending() }
        settleItem = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func measurePending() {
        guard !measuring, !pending.isEmpty else { return }
        let paths = pending.sorted()
        pending.removeAll()
        pendingSince = nil
        measuring = true
        measureQueue.async { [weak self] in
            let sizes = paths.map { (path: $0, bytes: Self.measure($0)) }
            guard let self else { return }
            queue.async { self.apply(sizes) }
        }
    }

    private func apply(_ sizes: [(path: String, bytes: Int64)]) {
        measuring = false
        let now = Date()
        var measurements: [Measurement] = []
        var alerts: [Alert] = []
        for (path, bytes) in sizes {
            guard var entry = tracked[path] else { continue }
            let measurement = Measurement(
                path: path, kind: entry.kind, bytes: bytes, previousBytes: entry.current,
                baselineBytes: entry.baseline, measuredAt: now
            )
            measurements.append(measurement)
            entry.current = bytes
            entry.samples.append((now, bytes))
            let horizon = now.addingTimeInterval(-2 * configuration.windowSeconds)
            if let keepFrom = entry.samples.lastIndex(where: { $0.date < horizon }) {
                entry.samples.removeFirst(keepFrom)
            }
            for reason in reasons(for: measurement, samples: entry.samples) {
                let key = reason.cooldownKey
                if let last = entry.lastAlert[key], now.timeIntervalSince(last) < configuration.alertCooldownSeconds { continue }
                entry.lastAlert[key] = now
                alerts.append(Alert(measurement: measurement, reason: reason))
            }
            tracked[path] = entry
        }
        if !measurements.isEmpty { onMeasure(measurements) }
        alerts.forEach(onAlert)
        // Changes that arrived while measuring.
        if !pending.isEmpty { scheduleMeasurement() }
    }

    private func reasons(for measurement: Measurement, samples: [(date: Date, bytes: Int64)]) -> [AlertReason] {
        var reasons: [AlertReason] = []
        let threshold = configuration.sizeThresholdBytes
        if measurement.previousBytes < threshold, measurement.bytes >= threshold {
            reasons.append(.crossedSize(threshold: threshold))
        }
        let growth = Self.windowGrowth(samples: samples, now: measurement.measuredAt, window: configuration.windowSeconds)
        if growth >= configuration.windowGrowthBytes {
            reasons.append(.fastGrowth(bytes: growth, window: configuration.windowSeconds))
        }
        return reasons
    }

    /// Growth over the last `window`: current size minus the smallest sample inside the window.
    /// When the only earlier sample is older than the window, its average rate is scaled to the window.
    static func windowGrowth(samples: [(date: Date, bytes: Int64)], now: Date, window: TimeInterval) -> Int64 {
        guard let current = samples.last else { return 0 }
        let start = now.addingTimeInterval(-window)
        let inside = samples.dropLast().filter { $0.date >= start }
        if let smallest = inside.map(\.bytes).min() {
            return max(0, current.bytes - smallest)
        }
        guard let before = samples.dropLast().last else { return 0 }
        let elapsed = now.timeIntervalSince(before.date)
        guard elapsed > 0 else { return 0 }
        let delta = Double(current.bytes - before.bytes)
        return max(0, Int64(delta * min(1, window / elapsed)))
    }

    /// Re-measures one artifact subtree with the bulk scanner.
    static func measure(_ path: String) -> Int64 {
        let tree = FileSystemScanner.scan(ScanOptions(roots: [path], workerCount: 2, priority: .background))
        return tree.stats.bytes
    }

    // MARK: Mapping changed directories to artifacts

    /// The tracked artifact containing `directory`, discovering a new one if allowed.
    private func locate(_ directory: String) -> String? {
        guard let root = roots.first(where: { directory == $0 || directory.hasPrefix($0 == "/" ? "/" : $0 + "/") }) else {
            return nil
        }
        var path = directory
        while path.count > root.count {
            if tracked[path] != nil { return path }
            if excludedPaths.contains(path) { return nil }
            path = (path as NSString).deletingLastPathComponent
        }
        guard configuration.discoverNewArtifacts else { return nil }
        return discover(in: directory, below: root)
    }

    /// Classifies ancestors of `directory` top-down (like the scanner) to find an artifact
    /// created after the last scan, and starts tracking it from zero.
    private func discover(in directory: String, below root: String) -> String? {
        var ancestors: [String] = []
        var path = directory
        while path.count > root.count {
            ancestors.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        for candidate in ancestors.reversed() {
            let name = (candidate as NSString).lastPathComponent
            guard Self.artifactNames.contains(name) else { continue }
            let parent = (candidate as NSString).deletingLastPathComponent
            let vendored = ArtifactRules.isVendored(parent + "/")
            guard let kind = ArtifactRules.classify(directoryName: name, parentMarkers: Self.markers(of: parent), vendored: vendored)
            else { continue }
            // `.git` is measured by full scans only; nothing inside it is an artifact.
            guard kind.isRegenerable else { return nil }
            tracked[candidate] = Tracked(kind: kind, baseline: 0, current: 0, samples: [(Date(), 0)])
            return candidate
        }
        return nil
    }

    /// Directory names `ArtifactRules.classify` can match.
    static let artifactNames: Set<String> = [
        "node_modules", ".git", ".terraform", ".terragrunt-cache", ".next", ".nuxt", ".svelte-kit", ".output",
        ".turbo", ".parcel-cache", ".angular", ".venv", "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache",
        ".tox", ".gradle", ".dart_tool", "DerivedData", "target", "venv", "vendor", "Pods", "build", "dist", "coverage",
    ]

    private static func markers(of directory: String) -> ProjectMarkers {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var markers: ProjectMarkers = []
        for name in names {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: directory + "/" + name, isDirectory: &isDirectory)
            if isDirectory.boolValue { continue }
            markers.formUnion(Array(name.utf8).withUnsafeBufferPointer(ProjectMarkers.match))
        }
        return markers
    }

    // MARK: Event id persistence

    private func storedEventID() -> FSEventStreamEventId? {
        guard let history, let root = roots.first,
              let stored = try? history.stateValue(forKey: Self.eventIDKey), let id = FSEventStreamEventId(stored),
              let database = FSEventsWatcher.eventDatabaseUUID(for: root),
              (try? history.stateValue(forKey: Self.eventDatabaseKey)) == database
        else { return nil }
        return id
    }

    private func saveEventID(_ id: FSEventStreamEventId) {
        guard let history, let root = roots.first, let database = FSEventsWatcher.eventDatabaseUUID(for: root) else { return }
        try? history.setStateValue(String(id), forKey: Self.eventIDKey)
        try? history.setStateValue(database, forKey: Self.eventDatabaseKey)
    }
}

private extension GrowthWatcher.AlertReason {
    var cooldownKey: String {
        switch self {
        case .crossedSize: "size"
        case .fastGrowth: "rate"
        }
    }
}
