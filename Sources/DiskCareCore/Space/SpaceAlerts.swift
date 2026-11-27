import Foundation

public enum SpaceLevel: String, Sendable, Codable, Comparable {
    case ok, low, critical

    private var rank: Int {
        switch self {
        case .ok: 0
        case .low: 1
        case .critical: 2
        }
    }

    public static func < (lhs: SpaceLevel, rhs: SpaceLevel) -> Bool { lhs.rank < rhs.rank }
}

/// Free-space warning levels, relative to the volume size so large disks warn early enough.
public struct SpaceThresholds: Sendable, Codable, Equatable {
    /// Low space: free below `max(minimumLowBytes, lowPercent% of total)`.
    public var minimumLowBytes: Int64
    public var lowPercent: Double
    /// Critical: free below `criticalPercent% of total` (never above the low threshold).
    public var criticalPercent: Double
    /// Alerts re-arm once free space is this much (percent of total) above the low threshold.
    public var resetMarginPercent: Double

    public init(minimumLowBytes: Int64 = 50_000_000_000, lowPercent: Double = 15, criticalPercent: Double = 8, resetMarginPercent: Double = 5) {
        self.minimumLowBytes = minimumLowBytes
        self.lowPercent = lowPercent
        self.criticalPercent = criticalPercent
        self.resetMarginPercent = resetMarginPercent
    }

    public func lowBytes(total: Int64) -> Int64 {
        max(minimumLowBytes, percent(lowPercent, of: total))
    }

    public func criticalBytes(total: Int64) -> Int64 {
        min(lowBytes(total: total), percent(criticalPercent, of: total))
    }

    public func resetBytes(total: Int64) -> Int64 {
        lowBytes(total: total) + percent(resetMarginPercent, of: total)
    }

    public func level(available: Int64, total: Int64) -> SpaceLevel {
        if available < criticalBytes(total: total) { return .critical }
        if available < lowBytes(total: total) { return .low }
        return .ok
    }

    private func percent(_ percent: Double, of total: Int64) -> Int64 {
        Int64((Double(total) * percent / 100).rounded())
    }
}

public enum SpaceAlert: String, Sendable, Codable {
    case warning, critical
    /// Free space is above the threshold but trending to full soon.
    case forecast
}

/// When each kind of alert was last sent. Persist it between checks.
public struct SpaceAlertState: Sendable, Codable, Equatable {
    public var lastWarningAt: Date?
    public var lastCriticalAt: Date?
    public var lastForecastAt: Date?

    public init(lastWarningAt: Date? = nil, lastCriticalAt: Date? = nil, lastForecastAt: Date? = nil) {
        self.lastWarningAt = lastWarningAt
        self.lastCriticalAt = lastCriticalAt
        self.lastForecastAt = lastForecastAt
    }
}

/// Decides which notification (if any) a free-space check should send. Pure: the caller measures
/// space, loads and saves the state, and posts the notification.
public struct SpaceAlertPolicy: Sendable {
    public var thresholds: SpaceThresholds
    public var warningInterval: TimeInterval
    public var criticalInterval: TimeInterval
    public var forecastInterval: TimeInterval
    /// Forecast alerts fire when the disk is predicted full within this many days.
    public var forecastHorizonDays: Double

    public init(
        thresholds: SpaceThresholds = SpaceThresholds(),
        warningInterval: TimeInterval = 86_400,
        criticalInterval: TimeInterval = 6 * 3600,
        forecastInterval: TimeInterval = 7 * 86_400,
        forecastHorizonDays: Double = 14
    ) {
        self.thresholds = thresholds
        self.warningInterval = warningInterval
        self.criticalInterval = criticalInterval
        self.forecastInterval = forecastInterval
        self.forecastHorizonDays = forecastHorizonDays
    }

    /// At most one alert per check, most severe first. Low-space alerts re-arm once free space
    /// rises above the threshold plus the reset margin. The forecast alert is only sent while free
    /// space is still above the low threshold (below it, the warnings already say so).
    public func evaluate(_ space: VolumeSpace, forecast: SpaceForecast? = nil, state: inout SpaceAlertState, now: Date) -> SpaceAlert? {
        let total = space.totalBytes, available = space.availableBytes
        if available > thresholds.resetBytes(total: total) {
            state.lastWarningAt = nil
            state.lastCriticalAt = nil
        }
        switch thresholds.level(available: available, total: total) {
        case .critical:
            guard isDue(state.lastCriticalAt, criticalInterval, now) else { return nil }
            state.lastCriticalAt = now
            state.lastWarningAt = now
            return .critical
        case .low:
            guard isDue(state.lastWarningAt, warningInterval, now) else { return nil }
            state.lastWarningAt = now
            return .warning
        case .ok:
            guard let days = forecast?.daysUntilFull, days < forecastHorizonDays,
                  isDue(state.lastForecastAt, forecastInterval, now) else { return nil }
            state.lastForecastAt = now
            return .forecast
        }
    }

    private func isDue(_ last: Date?, _ interval: TimeInterval, _ now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
