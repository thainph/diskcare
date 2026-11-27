import Foundation

/// How old the last full scan is, for the "Last full scan" label and the doctor.
public enum ScanStaleness: String, Sendable, Codable {
    case fresh
    /// Older than `ScanFreshness.agingDays`: shown in yellow.
    case aging
    /// Older than `ScanFreshness.staleDays`: shown in red.
    case stale
    /// No full scan recorded.
    case never
}

public enum ScanFreshness {
    public static let agingDays: Double = 2
    public static let staleDays: Double = 7

    public static func staleness(lastScan: Date?, now: Date = Date()) -> ScanStaleness {
        guard let lastScan else { return .never }
        let days = now.timeIntervalSince(lastScan) / 86_400
        if days > staleDays { return .stale }
        if days > agingDays { return .aging }
        return .fresh
    }

    /// Whether to scan right away (at launch, after wake): the last full scan is older than twice
    /// the scheduled interval, i.e. the background schedule has clearly been missing runs.
    public static func isScanDue(lastScan: Date?, intervalHours: Int, now: Date = Date()) -> Bool {
        guard let lastScan else { return true }
        return now.timeIntervalSince(lastScan) > 2 * Double(max(1, intervalHours)) * 3600
    }

    /// "just now", "5 hours ago", "1 day ago", "12 days ago".
    public static func ageText(lastScan: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(lastScan))
        if seconds < 3600 { return "just now" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = Int(seconds / 86_400)
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    /// Doctor result for the latest recorded scan (the CLI reads it from history.sqlite).
    public static func checkResult(lastScan: ScanRecord?, now: Date = Date()) -> CheckResult {
        let id = "scan-freshness", title = "Last full scan"
        let fix = "Keep the DiskCare menu bar app running (Settings → Launch at login) so it rescans on schedule, or run `diskcare scan`."
        guard let lastScan else {
            return CheckResult(id: id, title: title, status: .info, finding: "No scans recorded yet.", fix: fix)
        }
        let finding = "Last scan \(ageText(lastScan: lastScan.scannedAt, now: now)) "
            + "(\(lastScan.roots.map(\.abbreviatingHome).joined(separator: ", ")))."
        switch staleness(lastScan: lastScan.scannedAt, now: now) {
        case .fresh, .never:
            return CheckResult(id: id, title: title, status: .ok, finding: finding)
        case .aging:
            return CheckResult(id: id, title: title, status: .info, finding: finding, fix: fix)
        case .stale:
            return CheckResult(
                id: id, title: title, status: .warning,
                finding: finding + " Growth and low-space trends are out of date.", fix: fix
            )
        }
    }
}
