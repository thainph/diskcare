import AppKit
import DiskCareCore
import Foundation
import Observation
import UserNotifications

/// App state: latest scans, cleanup plan, background schedule and notifications.
@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    /// Scan history, 7-day growth and the live FSEvents growth watcher.
    let growth = GrowthModel()
    /// Global developer caches (~/Library/Caches, ~/.cache, package manager stores…).
    @ObservationIgnored private(set) lazy var caches = CachesModel(
        moveToTrash: { [settings] in settings.moveToTrash },
        onCleaned: { [weak self] _ in self?.refreshFreeSpace() }
    )

    private(set) var report: ScanReport?
    private(set) var dockerReport: DockerReport?
    private(set) var freeBytes: Int64?
    private(set) var totalBytes: Int64?
    private(set) var lastScanAt: Date?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastCleanupMessage: String?
    /// Plan items the user unchecked; kept across rescans by path.
    var deselected: Set<String> = []
    var selectedSection: MainSection? = .overview

    private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored var didStart = false
    private static let lastLowSpaceNotice = "lastLowSpaceNotice"

    init(settings: AppSettings) {
        self.settings = settings
        refreshFreeSpace()
        // Persist the FSEvents position so changes made while the app is closed are replayed next launch.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.growth.stopWatching() }
        }
    }

    /// Memoized: SwiftUI reads the plan many times per render (lists, totals, sidebar badges).
    var plan: [CleanupCandidate] {
        guard let report else { return [] }
        let key = PlanKey(scannedAt: report.scannedAt, idleDays: settings.idleDays,
                          minimumMB: settings.minimumArtifactMB, worktrees: settings.removeMergedWorktrees)
        if let cached = planCache, cached.key == key { return cached.plan }
        let plan = CleanupPlanner.plan(report, criteria: settings.criteria)
        planCache = (key, plan)
        return plan
    }

    private struct PlanKey: Equatable {
        let scannedAt: Date
        let idleDays: Int
        let minimumMB: Int
        let worktrees: Bool
    }

    @ObservationIgnored private var planCache: (key: PlanKey, plan: [CleanupCandidate])?

    // MARK: Snapshot

    /// Last results, restored at launch so the UI is useful immediately without a full rescan.
    private struct Snapshot: Codable {
        var report: ScanReport?
        var docker: DockerReport?
        var caches: CacheReport?
    }

    private static var snapshotURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/DiskCare/last-scan.json")
    }

    private func saveSnapshot() {
        let snapshot = Snapshot(report: report, docker: dockerReport, caches: caches.report)
        let url = Self.snapshotURL
        Task.detached(priority: .background) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        }
    }

    /// Returns the age of the restored data, or nil when nothing was saved.
    @discardableResult
    func restoreSnapshot() -> TimeInterval? {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        report = snapshot.report
        dockerReport = snapshot.docker
        if let caches = snapshot.caches { self.caches.restore(caches) }
        lastScanAt = snapshot.report?.scannedAt
        if let report { growth.startWatching(report) }
        return lastScanAt.map { Date().timeIntervalSince($0) }
    }

    var selectedPlan: [CleanupCandidate] {
        plan.filter { !deselected.contains($0.path) }
    }

    var planBytes: Int64 { plan.reduce(0) { $0 + $1.bytes } }

    /// Reclaimable space per source, in display order.
    var reclaimable: [(SpaceSource, Int64)] {
        [
            (.projects, planBytes),
            (.caches, caches.report?.safeReclaimableBytes ?? 0),
            (.docker, dockerReport?.safeReclaimableBytes ?? 0),
        ]
    }

    var reclaimableTotal: Int64 { reclaimable.reduce(0) { $0 + $1.1 } }

    func selectAllPlan() { deselected.removeAll() }

    func selectNoPlan() { deselected = Set(plan.map(\.path)) }

    func dismissCleanupMessage() { lastCleanupMessage = nil }

    var isLowOnSpace: Bool {
        freeBytes.map { $0 < settings.lowSpaceThresholdBytes } ?? false
    }

    var menuTitle: String {
        freeBytes.map { ByteFormat.string($0) } ?? "DiskCare"
    }

    // MARK: Scanning

    /// Starts a scan. Automatic scans use `.background` (few threads, throttled disk I/O) so the Mac
    /// stays responsive; an explicit "Scan now" uses `.userInitiated`.
    func scan(priority: ScanPriority = .userInitiated) {
        guard !isScanning, !isCleaning else { return }
        Task { await performScan(priority: priority) }
    }

    func performScan(priority: ScanPriority) async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        let options = ScanOptions(roots: settings.roots, priority: priority)
        // Docker is a cheap API call; the two filesystem scans run one after the other, never together.
        async let docker = DockerScanner.scan()
        let fileReport = await DiskAnalyzer.analyze(options)
        let dockerReport = await docker
        report = fileReport
        self.dockerReport = dockerReport
        lastScanAt = Date()
        refreshFreeSpace()
        growth.didScan(fileReport, freeBytes: freeBytes, dockerBytes: dockerReport.available ? dockerReport.totalBytes : nil)
        isScanning = false
        notifyIfLowOnSpace()

        await caches.refresh(priority: priority)
        saveSnapshot()
    }

    func refreshFreeSpace() {
        freeBytes = Cleaner.availableCapacity(at: NSHomeDirectory())
        totalBytes = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeTotalCapacityKey]))?
            .volumeTotalCapacity.map(Int64.init)
    }

    /// Rescans periodically when the system decides it is a good time (idle, on power…).
    func startSchedule() {
        scheduler?.invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.diskcare.app.scan")
        scheduler.repeats = true
        scheduler.interval = TimeInterval(max(1, settings.scanIntervalHours) * 3600)
        scheduler.tolerance = scheduler.interval / 4
        scheduler.qualityOfService = .background
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.performScan(priority: .background)
                completion(.finished)
            }
        }
        self.scheduler = scheduler
    }

    // MARK: Cleaning

    func cleanSelected() {
        let items = selectedPlan
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        lastCleanupMessage = nil
        let roots = report?.roots ?? settings.roots.map(ScanOptions.normalize)
        let mode: CleanupMode = settings.moveToTrash ? .trash : .delete
        let before = freeBytes
        Task {
            let outcomes = await Task.detached(priority: .userInitiated) {
                Cleaner.execute(items, roots: roots, mode: mode)
            }.value
            refreshFreeSpace()
            let failed = outcomes.filter { !$0.succeeded }
            var message = "Cleaned \(outcomes.count - failed.count)/\(outcomes.count) items"
            if let before, let after = freeBytes, after > before {
                message += ", +\(ByteFormat.string(after - before)) free"
            }
            if mode == .trash { message += " (empty Trash to reclaim)" }
            if let first = failed.first {
                message += ". Failed: \(URL(fileURLWithPath: first.candidate.path).lastPathComponent) – \(first.error ?? "error")"
            }
            lastCleanupMessage = message
            isCleaning = false
            deselected.removeAll()
            scan(priority: .background)
        }
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// At most one low-space notice per day.
    private func notifyIfLowOnSpace() {
        guard isLowOnSpace, let freeBytes else { return }
        let defaults = UserDefaults.standard
        let last = defaults.object(forKey: Self.lastLowSpaceNotice) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 86_400 else { return }
        defaults.set(Date(), forKey: Self.lastLowSpaceNotice)

        let reclaimable = selectedPlan.reduce(Int64(0)) { $0 + $1.bytes }
            + (dockerReport?.reclaimableBytes ?? 0)
        let content = UNMutableNotificationContent()
        content.title = "Disk almost full: \(ByteFormat.string(freeBytes)) free"
        content.body = reclaimable > 0
            ? "DiskCare found \(ByteFormat.string(reclaimable)) you can reclaim. Open DiskCare from the menu bar."
            : "Open DiskCare from the menu bar to see what is using space."
        let request = UNNotificationRequest(identifier: "low-space", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
