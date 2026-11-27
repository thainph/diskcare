import AppKit
import Charts
import DiskCareCore
import Observation
import SwiftUI
import UserNotifications

/// Scan history, growth over the last days and live growth alerts from FSEvents.
@MainActor
@Observable
final class GrowthModel {
    struct LiveAlert: Identifiable {
        let id = UUID()
        let alert: GrowthWatcher.Alert
        let date: Date
    }

    let days: Int
    /// Days of periodic free-space samples kept for the Insights chart.
    let historyDays: Int
    private(set) var report: GrowthReport?
    /// Periodic free-space samples of the last `historyDays`, oldest first.
    private(set) var freeHistory: [FreeSample] = []
    /// Artifacts and caches that grew the most over `days`: the same list space alerts name.
    private(set) var sources: [GrowthSource] = []
    private(set) var liveAlerts: [LiveAlert] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private var watcher: GrowthWatcher?
    @ObservationIgnored private let configuration: GrowthWatcher.Configuration

    init(
        store: HistoryStore? = try? HistoryStore(),
        days: Int = 7,
        historyDays: Int = 30,
        configuration: GrowthWatcher.Configuration = GrowthWatcher.Configuration()
    ) {
        self.store = store
        self.days = days
        self.historyDays = historyDays
        self.configuration = configuration
        if store == nil { errorMessage = L("History database unavailable", "Không mở được cơ sở dữ liệu lịch sử") }
        reload()
    }

    /// Call after every completed scan: records it, refreshes the growth list and
    /// (re)starts live watching of the scanned roots.
    func didScan(_ report: ScanReport, freeBytes: Int64?, dockerBytes: Int64? = nil, excludedPaths: Set<String> = []) {
        guard let store else { return }
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    _ = try store.record(report: report, freeBytes: freeBytes, dockerBytes: dockerBytes)
                }.value
            } catch {
                errorMessage = L("Could not record scan: \(error)", "Không ghi được lần quét: \(error)")
            }
            reload()
        }
        startWatching(report, excludedPaths: excludedPaths)
    }

    /// Records cache entry sizes after a cache scan (history for growth alerts).
    func didScanCaches(_ report: CacheReport) {
        guard let store else { return }
        Task {
            do {
                try await Task.detached(priority: .utility) { _ = try store.record(caches: report) }.value
            } catch {
                errorMessage = L("Could not record cache sizes: \(error)", "Không ghi được dung lượng cache: \(error)")
            }
            reload()
        }
    }

    /// Records a periodic free-space sample and returns the updated trend.
    func record(_ sample: FreeSample) async -> SpaceForecast? {
        guard let store else { return nil }
        do {
            let forecast = try await Task.detached(priority: .utility) {
                try store.record(sample: sample)
                return SpaceForecast.make(samples: try store.freeSamples(since: sample.date.addingTimeInterval(-14 * 86_400)), now: sample.date)
            }.value
            let start = sample.date.addingTimeInterval(-Double(historyDays) * 86_400)
            freeHistory = freeHistory.filter { $0.date >= start } + [sample]
            return forecast
        } catch {
            errorMessage = L("Could not record free space: \(error)", "Không ghi được dung lượng trống: \(error)")
            return nil
        }
    }

    /// Artifacts and caches that grew the most over the period, for notifications.
    func fastestGrowing(limit: Int = 3) async -> [GrowthSource] {
        guard let store else { return [] }
        let days = days
        return (try? await Task.detached(priority: .utility) {
            try GrowthAnalyzer.fastestGrowing(store, days: days, limit: limit)
        }.value) ?? []
    }

    func reload() {
        guard let store else { return }
        let days = days, historyDays = historyDays
        Task {
            do {
                let loaded = try await Task.detached(priority: .utility) {
                    let now = Date()
                    return (
                        report: try GrowthAnalyzer.analyze(store, days: days, now: now),
                        sources: try GrowthAnalyzer.fastestGrowing(store, days: days, limit: 10, now: now),
                        history: try store.freeSamples(since: now.addingTimeInterval(-Double(historyDays) * 86_400))
                    )
                }.value
                report = loaded.report
                sources = loaded.sources
                freeHistory = loaded.history
            } catch {
                errorMessage = L("Could not read history: \(error)", "Không đọc được lịch sử: \(error)")
            }
        }
    }

    /// Starts FSEvents watching, or refreshes baselines when the roots did not change.
    func startWatching(_ report: ScanReport, excludedPaths: Set<String> = []) {
        if let watcher, watcher.roots == report.roots {
            watcher.update(report: report)
            return
        }
        stopWatching()
        let watcher = GrowthWatcher(
            report: report, configuration: configuration, excludedPaths: excludedPaths, history: store
        ) { [weak self] alert in
            Task { @MainActor in self?.handle(alert) }
        }
        if watcher.start() { self.watcher = watcher }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    func dismissAlerts() {
        liveAlerts.removeAll()
    }

    private func handle(_ alert: GrowthWatcher.Alert) {
        liveAlerts.insert(LiveAlert(alert: alert, date: Date()), at: 0)
        if liveAlerts.count > 5 { liveAlerts.removeLast(liveAlerts.count - 5) }

        let content = UNMutableNotificationContent()
        content.title = alert.localizedTitle
        content.body = alert.localizedMessage
        content.sound = .default
        let request = UNNotificationRequest(identifier: "growth:\(alert.measurement.path)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Growth between the last scans plus live alerts; compact enough for an Overview card.
struct GrowthView: View {
    var model: GrowthModel
    var maxRows = 5
    var showsHeader = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader { HStack(alignment: .firstTextBaseline) {
                Text(L("Free space", "Dung lượng trống")).font(.headline)
                Text(L("last \(model.days) days", "\(model.days) ngày qua")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let change = model.report?.freeSpaceChange {
                    Text(L("free \(signedBytes(change))", "trống \(signedBytes(change))"))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(change < 0 ? .orange : .secondary)
                }
            } }
            if showsHeader, let points = model.report?.freeSpace, points.count > 1 {
                FreeSpaceSparkline(points: points)
            }
            if !model.liveAlerts.isEmpty { LiveAlertsView(model: model) }
            entries
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var entries: some View {
        if let report = model.report {
            if report.baseline == nil {
                Text(report.latest == nil
                     ? L("No scan history yet.", "Chưa có lịch sử quét.")
                     : L("Growth appears after the next scan.", "Mức tăng sẽ hiện sau lần quét tới."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if report.top.isEmpty {
                Text(L("Nothing grew by more than 100 MB in this period.", "Không có gì tăng quá 100 MB trong khoảng này."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                let alerted = Set(report.alerts.map(\.path))
                let rows = Array(report.top.prefix(maxRows))
                VStack(spacing: 0) {
                    ForEach(rows) { entry in
                        if entry.id != rows.first?.id { Divider() }
                        GrowthRow(
                            title: shortPath(entry.path, components: 2),
                            subtitle: entry.path.abbreviatingHome,
                            change: "\(entry.kind?.rawValue ?? L("workspace", "thư mục làm việc")) · \(entry.isNew ? L("new", "mới") : ByteFormat.string(entry.bytesThen)) → \(ByteFormat.string(entry.bytesNow))",
                            delta: entry.delta, path: entry.path, emphasized: alerted.contains(entry.path)
                        )
                    }
                }
            }
        }
    }
}

/// Fastest-growing artifacts and caches (the list space alerts name), for the Insights page.
struct GrowingFastestList: View {
    var model: GrowthModel
    var maxRows = 6
    /// Display name of a cache entry id (`homebrew` → "Homebrew").
    var cacheTitle: (String) -> String? = { _ in nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.liveAlerts.isEmpty { LiveAlertsView(model: model) }
            if model.sources.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let rows = Array(model.sources.prefix(maxRows))
                VStack(spacing: 0) {
                    ForEach(rows) { source in
                        if source.id != rows.first?.id { Divider() }
                        row(source)
                    }
                }
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func row(_ source: GrowthSource) -> some View {
        let then = source.bytesThen > 0 ? ByteFormat.string(source.bytesThen) : L("new", "mới")
        switch source.origin {
        case .cache:
            return GrowthRow(
                title: cacheTitle(source.name) ?? source.name,
                subtitle: L("Cache", "Cache") + " · \(then) → \(ByteFormat.string(source.bytesNow))",
                delta: source.delta, path: nil, emphasized: false
            )
        case .artifact:
            return GrowthRow(
                title: shortPath(source.name, components: 2),
                subtitle: source.name.abbreviatingHome,
                change: "\(then) → \(ByteFormat.string(source.bytesNow))",
                delta: source.delta, path: source.name, emphasized: false
            )
        }
    }

    private var emptyText: String {
        guard let report = model.report, report.baseline != nil else {
            return L("Growth appears after two scans a few days apart.", "Mức tăng sẽ hiện sau hai lần quét cách nhau vài ngày.")
        }
        return L("Nothing grew by more than 100 MB in the last \(model.days) days.",
                 "Không có gì tăng quá 100 MB trong \(model.days) ngày qua.")
    }
}

/// One growth line: name, detail, signed size change and Reveal in Finder.
private struct GrowthRow: View {
    let title: String
    let subtitle: String
    /// "new → 1.8 GB": shown on its own line under the full path.
    var change: String?
    let delta: Int64
    let path: String?
    /// Passed a growth alert threshold: bold with a warning icon, not color alone.
    let emphasized: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                // Full names and paths, wrapped: a truncated path is hard to recognise.
                Text(title).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let change {
                    Text(change).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 8)
            if emphasized {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .help(L("Grew faster than usual", "Tăng nhanh bất thường"))
                    .accessibilityLabel(L("Grew faster than usual", "Tăng nhanh bất thường"))
            }
            Text(signedBytes(delta))
                .font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(emphasized ? .orange : .primary)
            if let path { RevealInFinderButton(path: path) }
        }
        .padding(.vertical, 8)
        .help(path ?? title)
        .accessibilityElement(children: .combine)
    }
}

/// Live FSEvents alerts since launch, newest first.
private struct LiveAlertsView: View {
    var model: GrowthModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.liveAlerts) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.alert.localizedMessage).font(.callout).lineLimit(2)
                        Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    RevealInFinderButton(path: item.alert.measurement.path)
                }
            }
            Button(L("Dismiss", "Bỏ qua")) { model.dismissAlerts() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Icon-only button revealing `path` in Finder, labelled for VoiceOver.
struct RevealInFinderButton: View {
    let path: String

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "magnifyingglass").frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(L("Reveal in Finder", "Hiện trong Finder"))
        .accessibilityLabel(L("Reveal \(path.abbreviatingHome) in Finder", "Hiện \(path.abbreviatingHome) trong Finder"))
    }
}

private struct FreeSpaceSparkline: View {
    let points: [FreeSpacePoint]

    var body: some View {
        let values = points.map(\.freeBytes)
        let low = Double(values.min() ?? 0), high = Double(values.max() ?? 0)
        let padding = max((high - low) * 0.15, 1e9)
        Chart(points, id: \.date) { point in
            LineMark(x: .value("Date", point.date), y: .value("Free", Double(point.freeBytes) / 1e9))
                .interpolationMethod(.monotone)
            AreaMark(
                x: .value("Date", point.date),
                yStart: .value("Base", (low - padding) / 1e9),
                yEnd: .value("Free", Double(point.freeBytes) / 1e9)
            )
            .foregroundStyle(.linearGradient(colors: [.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            .interpolationMethod(.monotone)
        }
        .chartYScale(domain: (low - padding) / 1e9...(high + padding) / 1e9)
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                AxisValueLabel { Text("\(value.as(Double.self).map { Int($0.rounded()) } ?? 0) GB").font(.caption2) }
            }
        }
        .frame(height: 44)
        .accessibilityLabel(L("Free space trend", "Xu hướng dung lượng trống"))
        .accessibilityValue(summary)
    }

    private var summary: String {
        guard let first = points.first, let last = points.last else { return "" }
        return L("From \(ByteFormat.string(first.freeBytes)) to \(ByteFormat.string(last.freeBytes))",
                 "Từ \(ByteFormat.string(first.freeBytes)) đến \(ByteFormat.string(last.freeBytes))")
    }
}

extension GrowthWatcher.Alert {
    /// `alert.title` in the interface language.
    var localizedTitle: String {
        let name = URL(fileURLWithPath: measurement.path).lastPathComponent
        return L("\(name) is growing fast", "\(name) đang tăng nhanh")
    }

    /// `alert.message` in the interface language.
    var localizedMessage: String {
        let name = measurement.path.abbreviatingHome
        let now = ByteFormat.string(measurement.bytes)
        switch reason {
        case .crossedSize(let threshold):
            return L("\(name) is now \(now) (over \(ByteFormat.string(threshold))).",
                     "\(name) hiện đã \(now) (vượt \(ByteFormat.string(threshold))).")
        case .fastGrowth(let bytes, let window):
            let minutes = Int((window / 60).rounded())
            let period = minutes >= 60 && minutes % 60 == 0
                ? L("\(minutes / 60)h", "\(minutes / 60) giờ") : L("\(minutes) min", "\(minutes) phút")
            return L("\(name) grew \(ByteFormat.string(bytes)) in the last \(period), now \(now).",
                     "\(name) tăng \(ByteFormat.string(bytes)) trong \(period) qua, hiện \(now).")
        }
    }
}

/// "+1.2 GB" / "−300 MB".
func signedBytes(_ bytes: Int64) -> String {
    bytes < 0 ? "−" + ByteFormat.string(-bytes) : "+" + ByteFormat.string(bytes)
}

/// Last `components` path components: enough to recognise a folder without the full path.
private func shortPath(_ path: String, components: Int = 3) -> String {
    path.split(separator: "/").suffix(components).joined(separator: "/")
}
