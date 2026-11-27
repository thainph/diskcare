import DiskCareCore
import Foundation
import Observation

/// User preferences persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var roots: [String] {
        didSet { defaults.set(roots, forKey: Keys.roots) }
    }
    var idleDays: Int {
        didSet { defaults.set(idleDays, forKey: Keys.idleDays) }
    }
    var minimumArtifactMB: Int {
        didSet { defaults.set(minimumArtifactMB, forKey: Keys.minimumArtifactMB) }
    }
    var removeMergedWorktrees: Bool {
        didSet { defaults.set(removeMergedWorktrees, forKey: Keys.removeMergedWorktrees) }
    }
    var moveToTrash: Bool {
        didSet { defaults.set(moveToTrash, forKey: Keys.moveToTrash) }
    }
    var lowSpaceThresholdGB: Int {
        didSet { defaults.set(lowSpaceThresholdGB, forKey: Keys.lowSpaceThresholdGB) }
    }
    /// Low space also below this percentage of the disk, whichever threshold is larger.
    var lowSpacePercent: Int {
        didSet { defaults.set(lowSpacePercent, forKey: Keys.lowSpacePercent) }
    }
    var criticalSpacePercent: Int {
        didSet { defaults.set(criticalSpacePercent, forKey: Keys.criticalSpacePercent) }
    }
    var scanIntervalHours: Int {
        didSet { defaults.set(scanIntervalHours, forKey: Keys.scanIntervalHours) }
    }
    /// The first-run welcome screen was completed (shown once).
    var hasCompletedWelcome: Bool {
        didSet { defaults.set(hasCompletedWelcome, forKey: Keys.hasCompletedWelcome) }
    }

    init() {
        defaults.register(defaults: [
            Keys.roots: Self.defaultRoots(),
            Keys.idleDays: 30,
            Keys.minimumArtifactMB: 50,
            Keys.removeMergedWorktrees: false,
            Keys.moveToTrash: false,
            Keys.lowSpaceThresholdGB: 50,
            Keys.lowSpacePercent: 15,
            Keys.criticalSpacePercent: 8,
            Keys.scanIntervalHours: 6,
            Keys.hasCompletedWelcome: false,
        ])
        roots = defaults.stringArray(forKey: Keys.roots) ?? []
        idleDays = defaults.integer(forKey: Keys.idleDays)
        minimumArtifactMB = defaults.integer(forKey: Keys.minimumArtifactMB)
        removeMergedWorktrees = defaults.bool(forKey: Keys.removeMergedWorktrees)
        moveToTrash = defaults.bool(forKey: Keys.moveToTrash)
        lowSpaceThresholdGB = defaults.integer(forKey: Keys.lowSpaceThresholdGB)
        lowSpacePercent = defaults.integer(forKey: Keys.lowSpacePercent)
        criticalSpacePercent = defaults.integer(forKey: Keys.criticalSpacePercent)
        scanIntervalHours = defaults.integer(forKey: Keys.scanIntervalHours)
        hasCompletedWelcome = defaults.bool(forKey: Keys.hasCompletedWelcome)
    }

    var criteria: CleanupCriteria {
        CleanupCriteria(
            minimumIdleDays: idleDays,
            minimumBytes: Int64(minimumArtifactMB) * 1_000_000,
            removeMergedWorktrees: removeMergedWorktrees
        )
    }

    var spaceThresholds: SpaceThresholds {
        SpaceThresholds(
            minimumLowBytes: Int64(lowSpaceThresholdGB) * 1_000_000_000,
            lowPercent: Double(lowSpacePercent),
            criticalPercent: Double(criticalSpacePercent)
        )
    }

    /// Common code folders that exist on this machine.
    private static func defaultRoots() -> [String] {
        let home = NSHomeDirectory()
        let candidates = ["Workspace", "Tools", "Development", "Projects", "Code", "src", "dev"].map { home + "/" + $0 }
        let existing = candidates.filter { FileManager.default.fileExists(atPath: $0) }
        return existing.isEmpty ? [home] : existing
    }

    private enum Keys {
        static let roots = "roots"
        static let idleDays = "idleDays"
        static let minimumArtifactMB = "minimumArtifactMB"
        static let removeMergedWorktrees = "removeMergedWorktrees"
        static let moveToTrash = "moveToTrash"
        static let lowSpaceThresholdGB = "lowSpaceThresholdGB"
        static let lowSpacePercent = "lowSpacePercent"
        static let criticalSpacePercent = "criticalSpacePercent"
        static let scanIntervalHours = "scanIntervalHours"
        static let hasCompletedWelcome = "hasCompletedWelcome"
    }
}
