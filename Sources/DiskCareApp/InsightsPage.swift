import Charts
import DiskCareCore
import SwiftUI

/// Insights: free space over the last month, what grows fastest and where the rest of the disk goes.
struct InsightsPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            PageHeader(
                title: L("Insights", "Phân tích"),
                subtitle: L("How free space changed, what grows fastest and where the rest of the disk goes.",
                            "Dung lượng trống thay đổi ra sao, cái gì tăng nhanh nhất và phần còn lại của ổ nằm ở đâu.")
            )
            FreeSpaceHistoryCard(model: model)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                growingCard
                ExplainCard(model: model)
            }
        }
    }

    private var growingCard: some View {
        Card {
            InsightsCardHeader(
                title: L("Growing fastest", "Tăng nhanh nhất"), systemImage: "chart.line.uptrend.xyaxis",
                caption: L("last \(model.growth.days) days", "\(model.growth.days) ngày qua")
            )
            GrowingFastestList(model: model.growth) { model.caches.report?.entry(id: $0)?.title }
            Text(L("Low-space alerts name these when free space drops below the warning level.",
                   "Cảnh báo sắp đầy sẽ nêu tên các mục này khi dung lượng trống xuống dưới ngưỡng."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Card title with a small caption beside it, as in the mockup ("Growing fastest · last 7 days").
struct InsightsCardHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    var caption: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 8)
            trailing()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension InsightsCardHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, caption: String? = nil) {
        self.init(title: title, systemImage: systemImage, caption: caption) { EmptyView() }
    }
}

// MARK: Free space history

/// "Free space, last 30 days" from the 15-minute samples, with the warning level as a dashed rule.
private struct FreeSpaceHistoryCard: View {
    let model: AppModel

    var body: some View {
        let points = FreeSpaceHistory.points(model.growth.freeHistory)
        Card {
            InsightsCardHeader(
                title: L("Free space, last \(model.growth.historyDays) days", "Dung lượng trống, \(model.growth.historyDays) ngày qua"),
                systemImage: "internaldrive",
                caption: L("from the 15-minute samples", "từ các lần đo mỗi 15 phút")
            ) {
                trendPill
            }
            if points.count > 1 {
                FreeSpaceChart(points: points, warningBytes: warningBytes, level: model.spaceLevel)
                footer(points)
            } else {
                Text(L("DiskCare measures free space every 15 minutes. The chart fills in over the next hours.",
                       "DiskCare đo dung lượng trống mỗi 15 phút. Biểu đồ sẽ có dữ liệu sau vài giờ."))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private var warningBytes: Int64? {
        model.totalBytes.map { model.settings.spaceThresholds.lowBytes(total: $0) }
    }

    /// Disk level when it is low; otherwise the direction of the trend.
    @ViewBuilder
    private var trendPill: some View {
        if model.spaceLevel != .ok {
            StatusPill(level: model.spaceLevel)
        } else if let forecast = model.growth.report?.forecast ?? model.forecast {
            let perDay = forecast.bytesPerDay
            if let days = forecast.daysUntilFull, days < 30 {
                TrendPill(text: L("Filling up · full in ~\(max(1, Int(days.rounded()))) days", "Đang đầy dần · đầy sau ~\(max(1, Int(days.rounded()))) ngày"),
                          systemImage: "arrow.down.right", color: .orange)
            } else if perDay <= -1e9 {
                TrendPill(text: L("Falling \(ByteFormat.string(Int64(-perDay)))/day", "Giảm \(ByteFormat.string(Int64(-perDay)))/ngày"),
                          systemImage: "arrow.down.right", color: .orange)
            } else if perDay >= 1e9 {
                TrendPill(text: L("Rising", "Đang tăng"), systemImage: "arrow.up.right", color: .green)
            } else {
                TrendPill(text: L("Steady", "Ổn định"), systemImage: "arrow.right", color: .green)
            }
        } else {
            TrendPill(text: L("Collecting data", "Đang thu thập"), systemImage: "clock", color: .secondary)
        }
    }

    private func footer(_ points: [FreeSpaceHistory.Point]) -> some View {
        HStack {
            if let first = points.first {
                Text("\(FreeSpaceHistory.day(first.date)) · \(ByteFormat.string(first.freeBytes))")
            }
            Spacer()
            if let lowest = FreeSpaceHistory.lowest(points), lowest.date != points.last?.date {
                Text(L("Lowest \(ByteFormat.string(lowest.freeBytes)) · \(FreeSpaceHistory.day(lowest.date))",
                       "Thấp nhất \(ByteFormat.string(lowest.freeBytes)) · \(FreeSpaceHistory.day(lowest.date))"))
                Spacer()
            }
            if let last = points.last {
                Text(L("Now · \(ByteFormat.string(last.freeBytes))", "Hiện tại · \(ByteFormat.string(last.freeBytes))"))
            }
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        .accessibilityHidden(true)
    }
}

/// Colored capsule with an icon and words (color never alone).
private struct TrendPill: View {
    let text: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// Chart-ready series derived from the raw samples.
enum FreeSpaceHistory {
    struct Point: Equatable {
        let date: Date
        let freeBytes: Int64
    }

    /// Keeps at most `maximum` points: the lowest sample of each time bucket, so a dip never disappears.
    static func points(_ samples: [FreeSample], maximum: Int = 360) -> [Point] {
        guard samples.count > maximum, let first = samples.first?.date, let last = samples.last?.date, last > first else {
            return samples.map { Point(date: $0.date, freeBytes: $0.availableBytes) }
        }
        let width = last.timeIntervalSince(first) / Double(maximum)
        var buckets: [Int: FreeSample] = [:]
        for sample in samples {
            let index = min(maximum - 1, Int(sample.date.timeIntervalSince(first) / width))
            if let kept = buckets[index], kept.availableBytes <= sample.availableBytes { continue }
            buckets[index] = sample
        }
        var result = buckets.values.sorted { $0.date < $1.date }.map { Point(date: $0.date, freeBytes: $0.availableBytes) }
        // The chart ends at the latest measurement, whatever its bucket kept.
        if result.last?.date != last, let sample = samples.last {
            result.append(Point(date: sample.date, freeBytes: sample.availableBytes))
        }
        return result
    }

    static func lowest(_ points: [Point]) -> Point? {
        points.min { $0.freeBytes < $1.freeBytes }
    }

    /// "Nov 27" / "27 thg 11".
    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().locale(AppLanguage.resolved.locale))
    }
}

private struct FreeSpaceChart: View {
    let points: [FreeSpaceHistory.Point]
    let warningBytes: Int64?
    let level: SpaceLevel

    var body: some View {
        let lowest = FreeSpaceHistory.lowest(points)
        Chart {
            ForEach(points, id: \.date) { point in
                AreaMark(x: .value(L("Date", "Ngày"), point.date), y: .value(L("Free", "Trống"), gigabytes(point.freeBytes)))
                    .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value(L("Date", "Ngày"), point.date), y: .value(L("Free", "Trống"), gigabytes(point.freeBytes)))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let warningBytes {
                RuleMark(y: .value(L("Warning level", "Ngưỡng cảnh báo"), gigabytes(warningBytes)))
                    .foregroundStyle(.orange)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .annotation(position: .top, alignment: .leading) {
                        Text(L("warn at \(ByteFormat.string(warningBytes))", "cảnh báo ở \(ByteFormat.string(warningBytes))"))
                            .font(.caption).foregroundStyle(.orange)
                    }
            }
            if let lowest, lowest.date != points.last?.date {
                PointMark(x: .value(L("Date", "Ngày"), lowest.date), y: .value(L("Free", "Trống"), gigabytes(lowest.freeBytes)))
                    .foregroundStyle(lowestColor(lowest))
                    .symbolSize(60)
                    .annotation(position: .bottom, alignment: .center, spacing: 4) {
                        Text("\(ByteFormat.string(lowest.freeBytes)) · \(FreeSpaceHistory.day(lowest.date))")
                            .font(.caption.weight(.medium)).foregroundStyle(lowestColor(lowest))
                    }
            }
        }
        .chartYScale(domain: 0...yMaximum)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { Text("\(value.as(Double.self).map { Int($0.rounded()) } ?? 0) GB") }
            }
        }
        .environment(\.locale, AppLanguage.resolved.locale)
        .frame(height: 190)
        .accessibilityLabel(L("Free space chart", "Biểu đồ dung lượng trống"))
        .accessibilityValue(summary(lowest: lowest))
    }

    private var yMaximum: Double {
        let highest = max(points.map(\.freeBytes).max() ?? 0, warningBytes ?? 0)
        return max(1, gigabytes(highest) * 1.15)
    }

    private func lowestColor(_ point: FreeSpaceHistory.Point) -> Color {
        if let warningBytes, point.freeBytes < warningBytes { return .red }
        return level == .ok ? .secondary : .orange
    }

    /// Spoken instead of the plot: start, lowest, now and the warning level.
    private func summary(lowest: FreeSpaceHistory.Point?) -> String {
        guard let first = points.first, let last = points.last else { return "" }
        var parts = [L("Free space went from \(ByteFormat.string(first.freeBytes)) on \(FreeSpaceHistory.day(first.date)) to \(ByteFormat.string(last.freeBytes)) now",
                       "Dung lượng trống từ \(ByteFormat.string(first.freeBytes)) ngày \(FreeSpaceHistory.day(first.date)) đến \(ByteFormat.string(last.freeBytes)) hiện tại")]
        if let lowest, lowest.date != last.date {
            parts.append(L("lowest \(ByteFormat.string(lowest.freeBytes)) on \(FreeSpaceHistory.day(lowest.date))",
                           "thấp nhất \(ByteFormat.string(lowest.freeBytes)) ngày \(FreeSpaceHistory.day(lowest.date))"))
        }
        if let warningBytes {
            parts.append(L("warning level \(ByteFormat.string(warningBytes))", "ngưỡng cảnh báo \(ByteFormat.string(warningBytes))"))
        }
        return parts.joined(separator: "; ")
    }

    private func gigabytes(_ bytes: Int64) -> Double { Double(bytes) / 1e9 }
}
