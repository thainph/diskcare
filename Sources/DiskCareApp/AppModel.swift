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
    private(set) var lastScanAt: Date?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastCleanupMessage: String?
    /// Plan items the user unchecked; kept across rescans by path.
    var deselected: Set<String> = []
    var selectedSection: MainSection? = .overview

    private var scheduler: NSBackgroundActivityScheduler?
    private static let lastLowSpaceNotice = "lastLowSpaceNotice"

    init(settings: AppSettings) {
        self.settings = settings
        refreshFreeSpace()
        // Persist the FSEvents position so changes made while the app is closed are replayed next launch.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.growth.stopWatching() }
        }
    }

    var plan: [CleanupCandidate] {
        guard let report else { return [] }
        return CleanupPlanner.plan(report, criteria: settings.criteria)
    }

    var selectedPlan: [CleanupCandidate] {
        plan.filter { !deselected.contains($0.path) }
    }

    var isLowOnSpace: Bool {
        freeBytes.map { $0 < settings.lowSpaceThresholdBytes } ?? false
    }

    var menuTitle: String {
        freeBytes.map { ByteFormat.string($0) + " free" } ?? "DiskCare"
    }

    // MARK: Scanning

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        let options = ScanOptions(roots: settings.roots)
        Task {
            async let files = DiskAnalyzer.analyze(options)
            async let docker = DockerScanner.scan()
            let (fileReport, dockerReport) = await (files, docker)
            report = fileReport
            self.dockerReport = dockerReport
            lastScanAt = Date()
            refreshFreeSpace()
            growth.didScan(fileReport, freeBytes: freeBytes, dockerBytes: dockerReport.available ? dockerReport.totalBytes : nil)
            isScanning = false
            notifyIfLowOnSpace()
        }
    }

    func refreshFreeSpace() {
        freeBytes = Cleaner.availableCapacity(at: NSHomeDirectory())
    }

    /// Rescans periodically when the system decides it is a good time (idle, on power…).
    func startSchedule() {
        scheduler?.invalidate()
        let scheduler = NSBackgroundActivityScheduler(identifier: "dev.diskcare.app.scan")
        scheduler.repeats = true
        scheduler.interval = TimeInterval(max(1, settings.scanIntervalHours) * 3600)
        scheduler.tolerance = scheduler.interval / 4
        scheduler.qualityOfService = .utility
        scheduler.schedule { [weak self] completion in
            Task { @MainActor in
                self?.scan()
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
            scan()
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
