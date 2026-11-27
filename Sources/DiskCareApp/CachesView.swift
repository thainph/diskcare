import AppKit
import DiskCareCore
import Observation
import SwiftUI

/// Developer caches: measurement and selection. Cleaning runs through `AppModel.cleanReviewed`
/// together with projects, after one review.
@MainActor
@Observable
final class CachesModel {
    private(set) var report: CacheReport?
    private(set) var isScanning = false
    /// Selected entry and item ids (`homebrew`, `playwright/chromium-1228`).
    var selection: Set<String> = []

    /// Project roots, whose `.cargo/config.toml` files may point at shared build dirs.
    private let scanRoots: @MainActor () -> [String]
    /// `.terraform` dirs of the last project scan (nil before one): which provider versions are used.
    private let terraformDirs: @MainActor () -> [String]?
    /// Called after every fresh measurement (not for restored reports).
    private let onScanned: (@MainActor (CacheReport) -> Void)?

    init(
        scanRoots: @escaping @MainActor () -> [String] = { [] },
        terraformDirs: @escaping @MainActor () -> [String]? = { nil },
        onScanned: (@MainActor (CacheReport) -> Void)? = nil
    ) {
        self.scanRoots = scanRoots
        self.terraformDirs = terraformDirs
        self.onScanned = onScanned
    }

    var selectedTargets: [CacheCleanTarget] {
        guard let report else { return [] }
        let ids = selection.filter { report.entry(id: $0) != nil || report.item(id: $0) != nil }
        return (try? CacheCleaner.targets(ids: ids.sorted(), in: report)) ?? []
    }

    var selectedBytes: Int64 { selectedTargets.reduce(0) { $0 + $1.bytes } }

    func scan(priority: ScanPriority = .userInitiated) {
        guard !isScanning else { return }
        Task { await refresh(priority: priority) }
    }

    /// Measures caches; awaitable so callers can sequence it after other scans.
    func refresh(priority: ScanPriority, progress: ScanProgress? = nil) async {
        guard !isScanning else { return }
        isScanning = true
        let roots = scanRoots()
        var options = CacheScanner.Options(definitions: CacheCatalog.definitions(scanRoots: roots), priority: priority, progress: progress)
        options.scanRoots = roots
        options.terraformDirs = terraformDirs()
        let report = await CacheScanner.scan(options)
        apply(report)
        isScanning = false
        onScanned?(report)
    }

    /// Shows a previously saved report (app launch) until the next scan finishes.
    func restore(_ report: CacheReport) {
        guard self.report == nil else { return }
        apply(report)
    }

    private func apply(_ report: CacheReport) {
        self.report = report
        // Drop selections that no longer exist or are no longer cleanable.
        selection = selection.filter { id in
            if let entry = report.entry(id: id) { return entry.isCleanable }
            return report.item(id: id).flatMap { report.entry(id: $0.entryID) }?.safety.isCleanable ?? false
        }
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    /// `$caches[selected: id]` for checkboxes.
    subscript(selected id: String) -> Bool {
        get { selection.contains(id) }
        set { setSelected(id, newValue) }
    }

    func setSelected(_ id: String, _ selected: Bool) {
        if selected { selection.insert(id) } else { selection.remove(id) }
    }

    func selectAllSafe() {
        selection = Set(report?.allSafeIDs ?? [])
    }
}
