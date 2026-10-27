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
    private(set) var report: GrowthReport?
    private(set) var liveAlerts: [LiveAlert] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: HistoryStore?
    @ObservationIgnored private var watcher: GrowthWatcher?
    @ObservationIgnored private let configuration: GrowthWatcher.Configuration

    init(
        store: HistoryStore? = try? HistoryStore(),
        days: Int = 7,
        configuration: GrowthWatcher.Configuration = GrowthWatcher.Configuration()
    ) {
        self.store = store
        self.days = days
        self.configuration = configuration
        if store == nil { errorMessage = "History database unavailable" }
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
                errorMessage = "Could not record scan: \(error)"
            }
            reload()
        }
        startWatching(report, excludedPaths: excludedPaths)
    }

    func reload() {
        guard let store else { return }
        let days = days
        Task {
            do {
                report = try await Task.detached(priority: .utility) {
                    try GrowthAnalyzer.analyze(store, days: days)
                }.value
            } catch {
                errorMessage = "Could not read history: \(error)"
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
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        let request = UNNotificationRequest(identifier: "growth:\(alert.measurement.path)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

struct GrowthView: View {
    var model: GrowthModel
    var maxRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Growth").font(.headline)
                Text("last \(model.days)d").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let change = model.report?.freeSpaceChange {
                    Text("free \(signedBytes(change))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(change < 0 ? .orange : .secondary)
                }
            }
            if let points = model.report?.freeSpace, points.count > 1 {
                FreeSpaceSparkline(points: points)
            }
            if !model.liveAlerts.isEmpty { liveAlerts }
            entries
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var liveAlerts: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.liveAlerts) { item in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.alert.message).font(.caption).lineLimit(2)
                        Text(item.date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    revealButton(item.alert.measurement.path)
                }
            }
            Button("Dismiss") { model.dismissAlerts() }
                .buttonStyle(.link).font(.caption)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var entries: some View {
        if let report = model.report {
            if report.baseline == nil {
                Text(report.latest == nil ? "No scan history yet." : "Growth appears after the next scan.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if report.top.isEmpty {
                Text("No artifact grew more than 100 MB.").font(.caption).foregroundStyle(.secondary)
            } else {
                let alerted = Set(report.alerts.map(\.path))
                ForEach(report.top.prefix(maxRows)) { entry in
                    row(entry, alerted: alerted.contains(entry.path))
                }
            }
        }
    }

    private func row(_ entry: GrowthEntry, alerted: Bool) -> some View {
        HStack(spacing: 8) {
            Text(signedBytes(entry.delta))
                .font(.callout.monospacedDigit().weight(alerted ? .semibold : .regular))
                .foregroundStyle(alerted ? .orange : .primary)
                .frame(width: 72, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(shortPath(entry.path)).font(.callout).lineLimit(1).truncationMode(.head)
                Text("\(entry.kind?.rawValue ?? "workspace") · \(entry.isNew ? "new" : ByteFormat.string(entry.bytesThen)) → \(ByteFormat.string(entry.bytesNow))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            revealButton(entry.path)
        }
        .help(entry.path)
    }

    private func revealButton(_ path: String) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help("Show in Finder")
    }

    private func shortPath(_ path: String) -> String {
        path.split(separator: "/").suffix(3).joined(separator: "/")
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
        .accessibilityLabel("Free space trend")
    }
}

private func signedBytes(_ bytes: Int64) -> String {
    bytes < 0 ? "−" + ByteFormat.string(-bytes) : "+" + ByteFormat.string(bytes)
}
