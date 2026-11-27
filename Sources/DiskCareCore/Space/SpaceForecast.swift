import Foundation

/// One periodic free-space measurement (`free_samples` row).
public struct FreeSample: Sendable, Codable, Equatable {
    public let date: Date
    /// `df` free space.
    public let availableBytes: Int64
    /// Free space for important usage (includes purgeable).
    public let importantBytes: Int64?
    public let volumeUsedBytes: Int64?

    public init(date: Date, availableBytes: Int64, importantBytes: Int64? = nil, volumeUsedBytes: Int64? = nil) {
        self.date = date
        self.availableBytes = availableBytes
        self.importantBytes = importantBytes
        self.volumeUsedBytes = volumeUsedBytes
    }

    public init(date: Date, space: VolumeSpace) {
        self.init(date: date, availableBytes: space.availableBytes, importantBytes: space.importantAvailableBytes, volumeUsedBytes: space.volumeUsedBytes)
    }
}

/// Linear trend of free space over the last days.
public struct SpaceForecast: Sendable, Codable, Equatable {
    /// Change of free space per day (negative: the disk is filling up).
    public let bytesPerDay: Double
    public let sampleCount: Int
    public let since: Date
    public let until: Date
    /// Latest measured free space.
    public let availableBytes: Int64

    /// Days until free space reaches zero at the current rate; nil when it is not shrinking.
    public var daysUntilFull: Double? {
        guard bytesPerDay < 0 else { return nil }
        return max(0, Double(availableBytes) / -bytesPerDay)
    }

    public var fullAt: Date? {
        daysUntilFull.map { until.addingTimeInterval($0 * 86_400) }
    }

    /// Least-squares fit over the samples of the last `windowDays`. Requires at least `minimumSamples`
    /// spanning at least `minimumSpanDays`, so a single busy afternoon does not predict a full disk.
    /// The forecast starts from the latest real measurement, not the fitted line, so space freed by a
    /// recent cleanup counts immediately.
    public static func make(
        samples: [FreeSample],
        now: Date = Date(),
        windowDays: Double = 14,
        minimumSpanDays: Double = 7,
        minimumSamples: Int = 24
    ) -> SpaceForecast? {
        let start = now.addingTimeInterval(-windowDays * 86_400)
        let window = samples.filter { $0.date >= start && $0.date <= now }.sorted { $0.date < $1.date }
        guard window.count >= minimumSamples, let first = window.first, let last = window.last,
              last.date.timeIntervalSince(first.date) >= minimumSpanDays * 86_400 else { return nil }

        let xs = window.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys = window.map { Double($0.availableBytes) }
        let count = Double(window.count)
        let meanX = xs.reduce(0, +) / count, meanY = ys.reduce(0, +) / count
        var covariance = 0.0, variance = 0.0
        for (x, y) in zip(xs, ys) {
            covariance += (x - meanX) * (y - meanY)
            variance += (x - meanX) * (x - meanX)
        }
        guard variance > 0 else { return nil }
        return SpaceForecast(
            bytesPerDay: covariance / variance, sampleCount: window.count,
            since: first.date, until: last.date, availableBytes: last.availableBytes
        )
    }
}
