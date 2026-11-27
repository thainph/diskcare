import Foundation
import Testing
@testable import DiskCareCore

private let GB: Int64 = 1_000_000_000
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86_400

private func space(free: Int64, total: Int64 = 500 * GB) -> VolumeSpace {
    VolumeSpace(totalBytes: total, availableBytes: free)
}

@Suite struct SpaceThresholdsTests {
    @Test func lowIsTheLargerOfGigabytesAndPercent() {
        let thresholds = SpaceThresholds()
        // 15% of 500 GB = 75 GB beats the 50 GB floor; critical is 8%.
        #expect(thresholds.lowBytes(total: 500 * GB) == 75 * GB)
        #expect(thresholds.criticalBytes(total: 500 * GB) == 40 * GB)
        // 15% of 256 GB = 38.4 GB, below the 50 GB floor.
        #expect(thresholds.lowBytes(total: 256 * GB) == 50 * GB)
        #expect(thresholds.criticalBytes(total: 256 * GB) == 20_480_000_000)
        // Reset margin: threshold + 5% of total.
        #expect(thresholds.resetBytes(total: 500 * GB) == 100 * GB)
    }

    @Test func levels() {
        let thresholds = SpaceThresholds()
        #expect(thresholds.level(available: 75 * GB, total: 500 * GB) == .ok)
        #expect(thresholds.level(available: 75 * GB - 1, total: 500 * GB) == .low)
        #expect(thresholds.level(available: 40 * GB, total: 500 * GB) == .low)
        #expect(thresholds.level(available: 40 * GB - 1, total: 500 * GB) == .critical)
    }

    @Test func criticalNeverExceedsLow() {
        let thresholds = SpaceThresholds(minimumLowBytes: 10 * GB, lowPercent: 5, criticalPercent: 8)
        #expect(thresholds.criticalBytes(total: 500 * GB) == thresholds.lowBytes(total: 500 * GB))
    }

    @Test func purgeableIsImportantMinusAvailable() {
        #expect(VolumeSpace(totalBytes: 500 * GB, availableBytes: 100 * GB, importantAvailableBytes: 108 * GB).purgeableBytes == 8 * GB)
        #expect(VolumeSpace(totalBytes: 500 * GB, availableBytes: 100 * GB, importantAvailableBytes: 90 * GB).purgeableBytes == 0)
        #expect(VolumeSpace(totalBytes: 500 * GB, availableBytes: 100 * GB).purgeableBytes == 0)
    }

    @Test func measuresTheRealVolume() throws {
        let measured = try #require(VolumeSpace.measure(at: NSTemporaryDirectory()))
        #expect(measured.totalBytes > 0)
        #expect(measured.availableBytes > 0 && measured.availableBytes <= measured.totalBytes)
        if let used = measured.volumeUsedBytes { #expect(used <= measured.totalBytes) }
        #expect(VolumeSpace.available(at: NSTemporaryDirectory()) != nil)
    }
}

@Suite struct SpaceAlertPolicyTests {
    let policy = SpaceAlertPolicy()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func warningAtMostOncePerDay() {
        var state = SpaceAlertState()
        #expect(policy.evaluate(space(free: 70 * GB), state: &state, now: start) == .warning)
        #expect(policy.evaluate(space(free: 69 * GB), state: &state, now: start + hour) == nil)
        #expect(policy.evaluate(space(free: 68 * GB), state: &state, now: start + 23 * hour) == nil)
        #expect(policy.evaluate(space(free: 68 * GB), state: &state, now: start + day) == .warning)
    }

    @Test func criticalEscalatesImmediatelyThenEverySixHours() {
        var state = SpaceAlertState()
        #expect(policy.evaluate(space(free: 70 * GB), state: &state, now: start) == .warning)
        #expect(policy.evaluate(space(free: 30 * GB), state: &state, now: start + 60) == .critical)
        #expect(policy.evaluate(space(free: 29 * GB), state: &state, now: start + 2 * hour) == nil)
        #expect(policy.evaluate(space(free: 29 * GB), state: &state, now: start + 6 * hour + 60) == .critical)
        // Back to merely low: the critical alert counted as the day's warning.
        #expect(policy.evaluate(space(free: 60 * GB), state: &state, now: start + 7 * hour) == nil)
    }

    @Test func resetsOnlyAboveThresholdPlusMargin() {
        var state = SpaceAlertState()
        #expect(policy.evaluate(space(free: 70 * GB), state: &state, now: start) == .warning)
        // 90 GB: above the 75 GB threshold but below the 100 GB reset level. No re-arm.
        #expect(policy.evaluate(space(free: 90 * GB), state: &state, now: start + hour) == nil)
        #expect(policy.evaluate(space(free: 70 * GB), state: &state, now: start + 2 * hour) == nil)
        // 101 GB re-arms; the next drop warns right away.
        #expect(policy.evaluate(space(free: 101 * GB), state: &state, now: start + 3 * hour) == nil)
        #expect(state == SpaceAlertState())
        #expect(policy.evaluate(space(free: 70 * GB), state: &state, now: start + 4 * hour) == .warning)
    }

    @Test func forecastAtMostOncePerWeekAndOnlyAboveThreshold() {
        let filling = SpaceForecast(bytesPerDay: -10 * Double(GB), sampleCount: 100, since: start - 10 * day, until: start, availableBytes: 100 * GB)
        let slow = SpaceForecast(bytesPerDay: -1 * Double(GB), sampleCount: 100, since: start - 10 * day, until: start, availableBytes: 100 * GB)
        var state = SpaceAlertState()
        #expect(policy.evaluate(space(free: 200 * GB), forecast: slow, state: &state, now: start) == nil, "full in 100 days")
        #expect(policy.evaluate(space(free: 200 * GB), forecast: filling, state: &state, now: start) == .forecast)
        #expect(policy.evaluate(space(free: 200 * GB), forecast: filling, state: &state, now: start + 3 * day) == nil)
        #expect(policy.evaluate(space(free: 200 * GB), forecast: filling, state: &state, now: start + 7 * day) == .forecast)
        // Below the threshold the low-space warning is sent instead.
        var low = SpaceAlertState()
        #expect(policy.evaluate(space(free: 70 * GB), forecast: filling, state: &low, now: start) == .warning)
        #expect(low.lastForecastAt == nil)
    }
}

@Suite struct SpaceForecastTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func samples(days: Double, every interval: TimeInterval = hour, startFree: Double, perDay: Double) -> [FreeSample] {
        stride(from: -days * day, through: 0, by: interval).map { offset in
            let elapsed = (offset + days * day) / day
            return FreeSample(date: now + offset, availableBytes: Int64(startFree + perDay * elapsed))
        }
    }

    @Test func linearTrend() throws {
        let forecast = try #require(SpaceForecast.make(samples: samples(days: 10, startFree: 100e9, perDay: -5e9), now: now))
        #expect(abs(forecast.bytesPerDay - -5e9) < 1e6)
        #expect(forecast.availableBytes == 50 * GB)
        #expect(abs(try #require(forecast.daysUntilFull) - 10) < 0.01)
        #expect(forecast.fullAt.map { abs($0.timeIntervalSince(now + 10 * day)) < 3600 } == true)
    }

    @Test func usesOnlyTheLastFourteenDays() throws {
        // Old rising data must not dilute the recent falling trend.
        let old = samples(days: 30, startFree: 0, perDay: 10e9).filter { $0.date < now - 15 * day }
        let recent = samples(days: 10, startFree: 100e9, perDay: -2e9)
        let forecast = try #require(SpaceForecast.make(samples: old + recent, now: now))
        #expect(abs(forecast.bytesPerDay - -2e9) < 1e6)
        #expect(forecast.sampleCount == recent.count)
    }

    @Test func needsEnoughSamplesAndSpan() {
        // 3 days of 15-minute samples: plenty of samples, too short a span.
        #expect(SpaceForecast.make(samples: samples(days: 3, every: 900, startFree: 100e9, perDay: -5e9), now: now) == nil)
        // 8 days but only 9 samples.
        #expect(SpaceForecast.make(samples: samples(days: 8, every: day, startFree: 100e9, perDay: -5e9), now: now) == nil)
        #expect(SpaceForecast.make(samples: samples(days: 8, every: 4 * hour, startFree: 100e9, perDay: -5e9), now: now) != nil)
    }

    @Test func notShrinkingMeansNoFullDate() throws {
        let forecast = try #require(SpaceForecast.make(samples: samples(days: 10, startFree: 100e9, perDay: 1e9), now: now))
        #expect(forecast.daysUntilFull == nil)
        #expect(forecast.fullAt == nil)
    }
}
