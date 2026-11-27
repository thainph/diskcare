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
        onCleaned: { [weak self] _ in self?.refreshFreeSpace() },
        onScanned: { [weak self] report in self?.growth.didScanCaches(report) }
    )

    private(set) var report: ScanReport?
    private(set) var dockerReport: DockerReport?
    private(set) var space: VolumeSpace?
    /// Trend of the periodic free-space samples (nil until there are enough).
    private(set) var forecast: SpaceForecast?
    private(set) var lastScanAt: Date?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastCleanupMessage: String?
    /// Plan items the user unchecked; kept across rescans by path.
    var deselected: Set<String> = []
    var selectedSection: MainSection? = .overview

    private var scheduler: NSBackgroundActivityScheduler?
    @ObservationIgnored private var spaceMonitor: Task<Void, Never>?
    @ObservationIgnored var didStart = false
    private static let spaceAlertState = "spaceAlertState"
    /// Free-space check interval: resource values only, no scanning.
    static let spaceCheckInterval: Duration = .seconds(15 * 60)

    init(settings: AppSettings) {
        self.settings = settings
        refreshFreeSpace()
        // Persist the FSEvents position so changes made while the app is closed are replayed next launch.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.growth.stopWatching() }
        }
        // A Mac that sleeps a lot misses scheduled scans: catch up after wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                LaunchAtLogin.shared.refresh()
                self?.scanIfDue()
            }
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

    /// Size label for a source, or why there is no number yet.
    func valueText(for source: SpaceSource, bytes: Int64, empty: String = "—") -> String {
        if bytes > 0 { return ByteFormat.string(bytes) }
        switch source {
        case .projects where report == nil, .caches where caches.report == nil:
            return isScanning ? "pending" : "not scanned"
        case .docker where dockerReport == nil:
            return isScanning ? "pending" : "not scanned"
        case .docker where dockerReport?.available == false:
            return "not running"
        default:
            return empty
        }
    }

    func selectAllPlan() { deselected.removeAll() }

    func selectNoPlan() { deselected = Set(plan.map(\.path)) }

    func dismissCleanupMessage() { lastCleanupMessage = nil }

    /// `df` free space; alerts use this.
    var freeBytes: Int64? { space?.availableBytes }
    var totalBytes: Int64? { space?.totalBytes }
    /// Purgeable space on top of `freeBytes`; nil when there is none worth showing.
    var purgeableBytes: Int64? { space.map(\.purgeableBytes).flatMap { $0 >= 1_000_000_000 ? $0 : nil } }

    var spaceLevel: SpaceLevel {
        guard let space else { return .ok }
        return settings.spaceThresholds.level(available: space.availableBytes, total: space.totalBytes)
    }

    var isLowOnSpace: Bool { spaceLevel != .ok }

    /// The effective low-space threshold for this disk (max of the GB and percentage settings).
    var lowSpaceThresholdBytes: Int64? {
        space.map { settings.spaceThresholds.lowBytes(total: $0.totalBytes) }
    }

    /// Banner text when free space is below a threshold.
    var lowSpaceMessage: String? {
        guard let space, let threshold = lowSpaceThresholdBytes else { return nil }
        switch spaceLevel {
        case .ok: return nil
        case .low: return "Free space is below your \(ByteFormat.string(threshold)) warning level."
        case .critical:
            let critical = settings.spaceThresholds.criticalBytes(total: space.totalBytes)
            return "Free space is critically low (below \(ByteFormat.string(critical)))."
        }
    }

    /// "Full in ~9 days" when the trend predicts a full disk within two weeks.
    var forecastText: String? {
        guard let days = forecast?.daysUntilFull, days < 14 else { return nil }
        return days < 1 ? "At the current rate the disk fills up within a day" : "At the current rate the disk is full in ~\(Int(days.rounded())) days"
    }

    var scanStaleness: ScanStaleness {
        ScanFreshness.staleness(lastScan: lastScanAt)
    }

    /// "Last full scan: 3 days ago".
    var lastScanText: String {
        guard let lastScanAt else { return "No full scan yet" }
        return "Last full scan: \(ScanFreshness.ageText(lastScan: lastScanAt))"
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

    /// What a running scan is doing, for the progress UI.
    struct ScanStatus: Equatable {
        var step: Int
        var totalSteps: Int
        var title: String
        var detail: String = ""

        var fraction: Double { Double(step - 1) / Double(max(1, totalSteps)) }
    }

    private(set) var scanStatus: ScanStatus?

    /// Scans step by step — each root, then Docker, then caches — never several at once.
    /// The UI updates after every root, keeping the previous results for roots not rescanned yet.
    func performScan(priority: ScanPriority) async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        let roots = settings.roots.map(ScanOptions.normalize).filter { FileManager.default.fileExists(atPath: $0) }
        let totalSteps = roots.count + 2
        let progress = ScanProgress()
        let ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshStatusDetail(progress)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer {
            ticker.cancel()
            scanStatus = nil
            isScanning = false
        }

        var fresh: [ScanReport] = []
        for (index, root) in roots.enumerated() {
            scanStatus = ScanStatus(step: index + 1, totalSteps: totalSteps, title: "Scanning \(root.abbreviatingHome)")
            progress.reset()
            let rootReport = await DiskAnalyzer.analyze(ScanOptions(roots: [root], priority: priority, progress: progress))
            fresh.append(rootReport)
            report = report?.replacing(root: root, with: rootReport) ?? rootReport
        }
        if let combined = ScanReport.combining(fresh) { report = combined }

        scanStatus = ScanStatus(step: roots.count + 1, totalSteps: totalSteps, title: "Checking Docker")
        let dockerReport = await DockerScanner.scan()
        self.dockerReport = dockerReport
        lastScanAt = Date()
        refreshFreeSpace()
        if let report {
            // `scans.free_bytes` keeps its original meaning: free space for important usage.
            growth.didScan(report, freeBytes: space?.importantAvailableBytes, dockerBytes: dockerReport.available ? dockerReport.totalBytes : nil)
        }
        evaluateSpaceAlerts()

        scanStatus = ScanStatus(step: roots.count + 2, totalSteps: totalSteps, title: "Measuring developer caches")
        progress.reset()
        await caches.refresh(priority: priority, progress: progress)
        saveSnapshot()
    }

    private func refreshStatusDetail(_ progress: ScanProgress) {
        guard var status = scanStatus else { return }
        let git = progress.gitInspected
        if git.total > 0 {
            status.detail = "git status \(git.done) of \(git.total) repositories"
        } else if progress.files > 0 {
            status.detail = "\(progress.files.formatted()) files"
        } else {
            status.detail = ""
        }
        if status != scanStatus { scanStatus = status }
    }

    func refreshFreeSpace() {
        space = VolumeSpace.measure(at: NSHomeDirectory())
    }

    /// Checks free space every 15 minutes, independently of scans: records a sample, updates the
    /// forecast and sends low-space alerts.
    func startSpaceMonitor() {
        spaceMonitor?.cancel()
        spaceMonitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkSpace()
                try? await Task.sleep(for: Self.spaceCheckInterval)
            }
        }
    }

    func checkSpace() async {
        refreshFreeSpace()
        guard let space else { return }
        forecast = await growth.record(FreeSample(date: Date(), space: space))
        evaluateSpaceAlerts()
    }

    /// Scans in the background right away when the last full scan is older than twice the schedule
    /// interval (launch, wake from sleep).
    func scanIfDue() {
        guard ScanFreshness.isScanDue(lastScan: lastScanAt, intervalHours: settings.scanIntervalHours) else { return }
        scan(priority: .background)
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

    /// Sends at most one space alert, rate limited by `SpaceAlertPolicy` (state kept in UserDefaults).
    private func evaluateSpaceAlerts(now: Date = Date()) {
        guard let space else { return }
        let defaults = UserDefaults.standard
        var state = defaults.data(forKey: Self.spaceAlertState)
            .flatMap { try? JSONDecoder().decode(SpaceAlertState.self, from: $0) } ?? SpaceAlertState()
        let policy = SpaceAlertPolicy(thresholds: settings.spaceThresholds)
        let alert = policy.evaluate(space, forecast: forecast, state: &state, now: now)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.spaceAlertState) }
        guard let alert else { return }
        Task { postSpaceAlert(alert, space: space, sources: await growth.fastestGrowing(limit: 3)) }
    }

    private func postSpaceAlert(_ alert: SpaceAlert, space: VolumeSpace, sources: [GrowthSource]) {
        let free = ByteFormat.string(space.availableBytes)
        let content = UNMutableNotificationContent()
        var lines: [String] = []
        switch alert {
        case .critical:
            content.title = "Disk critically low: \(free) free"
        case .warning:
            content.title = "Disk almost full: \(free) free"
        case .forecast:
            content.title = forecastText ?? "Disk is filling up"
            if let perDay = forecast?.bytesPerDay {
                lines.append("Free space is falling by about \(ByteFormat.string(Int64(-perDay))) a day (\(free) free now).")
            }
        }
        if alert != .forecast, let forecastText { lines.append(forecastText + ".") }
        if !sources.isEmpty {
            lines.append("Growing fastest: " + sources.map { "\(label(for: $0)) +\(ByteFormat.string($0.delta))" }.joined(separator: ", ") + ".")
        }
        let reclaimable = selectedPlan.reduce(Int64(0)) { $0 + $1.bytes }
            + (dockerReport?.reclaimableBytes ?? 0)
        lines.append(reclaimable > 0
            ? "DiskCare found \(ByteFormat.string(reclaimable)) you can reclaim. Open DiskCare from the menu bar."
            : "Open DiskCare from the menu bar to see what is using space.")
        content.body = lines.joined(separator: " ")
        if alert == .critical { content.sound = .default }
        let identifier = alert == .forecast ? "space-forecast" : "low-space"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Short name for a growth source: cache title, or the artifact's parent folder and name.
    private func label(for source: GrowthSource) -> String {
        switch source.origin {
        case .cache:
            return caches.report?.entry(id: source.name)?.title ?? source.name
        case .artifact:
            let url = URL(fileURLWithPath: source.name)
            return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
        }
    }
}
