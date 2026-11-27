import AppKit
import DiskCareCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview, cleanup, insights, prevention

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: L("Overview", "Tổng quan")
        case .cleanup: L("Clean up", "Dọn dẹp")
        case .insights: L("Insights", "Phân tích")
        case .prevention: L("Prevention", "Phòng ngừa")
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .cleanup: "sparkles"
        case .insights: "chart.line.uptrend.xyaxis"
        case .prevention: "checkmark.shield"
        }
    }
}

/// Which part of the Clean up page is shown.
enum CleanupFilter: String, CaseIterable, Identifiable {
    case all, projects, caches, docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("All", "Tất cả")
        case .projects: L("Projects", "Dự án")
        case .caches: L("Caches", "Cache")
        case .docker: "Docker"
        }
    }
}

struct MainWindow: View {
    static let windowID = "main"

    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                ForEach(MainSection.allCases) { section in
                    sidebarRow(section).tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { MonitoringStatus(model: model).padding(10) }
        } detail: {
            detail(model.selectedSection ?? .overview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle((model.selectedSection ?? .overview).title)
                .toolbar {
                    ToolbarItemGroup {
                        if let status = model.scanStatus {
                            Text("\(status.title) (\(status.step)/\(status.totalSteps))")
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView().controlSize(.small)
                        } else {
                            Text(model.lastScanText).font(.caption).foregroundStyle(.secondary)
                        }
                        Button {
                            model.scan()
                        } label: {
                            Label(L("Scan now", "Quét ngay"), systemImage: "arrow.clockwise")
                        }
                        .help(L("Scan projects, caches and Docker again", "Quét lại dự án, cache và Docker"))
                        .disabled(model.isScanning || model.isCleaning)
                        Button {
                            openWindow(id: SettingsView.windowID)
                        } label: {
                            Label(L("Settings", "Cài đặt"), systemImage: "gearshape")
                        }
                        .help(L("Settings", "Cài đặt"))
                    }
                }
        }
        .frame(minWidth: 900, minHeight: 620)
        .containerBackground(.thinMaterial, for: .window)
        .sheet(isPresented: $model.isReviewing) { ReviewSheet(model: model) }
        .id(model.settings.language)
    }

    @ViewBuilder
    private func sidebarRow(_ section: MainSection) -> some View {
        let label = Label(section.title, systemImage: section.systemImage)
        switch section {
        case .cleanup where model.safeCleanBytes > 0:
            label.badge(Text(ByteFormat.string(model.safeCleanBytes)).monospacedDigit())
        case .insights where !model.growth.liveAlerts.isEmpty:
            label.badge(model.growth.liveAlerts.count)
        default:
            label
        }
    }

    @ViewBuilder
    private func detail(_ section: MainSection) -> some View {
        switch section {
        case .overview: OverviewView(model: model)
        case .cleanup: CleanupPage(model: model)
        case .insights: InsightsPage(model: model)
        case .prevention: DoctorPage(model: model)
        }
    }
}

/// Sidebar footer: is DiskCare actually watching the disk?
struct MonitoringStatus: View {
    let model: AppModel
    private let launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(isOn ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(isOn ? L("Monitoring on", "Đang theo dõi") : L("Monitoring paused", "Chưa theo dõi liên tục"))
                    .font(.callout.weight(.semibold))
            }
            Text(isOn
                 ? L("Checks free space every 15 min. Launch at login is on.", "Kiểm tra dung lượng mỗi 15 phút. Đã bật mở cùng máy.")
                 : L("Turn on Launch at login so DiskCare keeps watching.", "Bật mở cùng máy để DiskCare theo dõi liên tục."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(cornerRadius: 14)
    }

    private var isOn: Bool { !launchAtLogin.needsAttention }
}

/// Shared page scaffold: scrollable, consistent padding and spacing.
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .padding(Metrics.pagePadding)
                .frame(maxWidth: 1080, alignment: .leading)
        }
    }
}

// MARK: Overview

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            PageHeader(
                title: "Overview",
                subtitle: "How your startup disk is used and how much DiskCare can safely free."
            )
            if let status = model.scanStatus {
                Card { ScanStatusView(status: status) }
            }
            if let message = model.lowSpaceMessage {
                StatusBanner(message: message + " Start with the largest item below.", isError: true)
            } else if let forecast = model.forecastText {
                StatusBanner(message: forecast + ". Start with the largest item below.", isError: true)
            }
            LaunchAtLoginBanner()
            diskCard
            reclaimCard
            ExplainCard(model: model)
            if !model.growth.liveAlerts.isEmpty || (model.growth.report?.alerts.isEmpty == false) {
                Card(title: "Growing fast", systemImage: "chart.line.uptrend.xyaxis") {
                    GrowthView(model: model.growth, maxRows: 3, showsHeader: false)
                    Button("See growth details") { model.selectedSection = .insights }.buttonStyle(.link)
                }
            }
        }
    }

    private var diskCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.freeBytes.map(ByteFormat.string) ?? "–")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.isLowOnSpace ? .red : .primary)
                Text("free").font(.title3).foregroundStyle(.secondary)
                if let total = model.totalBytes {
                    Text("of \(ByteFormat.string(total))").font(.title3).foregroundStyle(.secondary)
                }
                if let purgeable = model.purgeableBytes {
                    Text("+\(ByteFormat.string(purgeable)) purgeable").font(.callout).foregroundStyle(.secondary)
                        .help("Space macOS can free on demand (snapshots, iCloud copies). Not counted as free by df.")
                }
                Spacer()
                LastScanLabel(model: model)
            }
            if let total = model.totalBytes, let free = model.freeBytes {
                DiskUsageBar(totalBytes: total, freeBytes: free, reclaimable: model.reclaimable, height: 18)
            }
        }
    }

    private var reclaimCard: some View {
        Card {
            HStack(alignment: .firstTextBaseline) {
                Text("You can free up").font(.headline)
                Text(ByteFormat.string(model.reclaimableTotal)).font(.headline).monospacedDigit()
                Spacer()
                if model.isScanning {
                    Text("updating…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(sortedSources, id: \.0) { source, bytes in
                Divider()
                HStack(spacing: 12) {
                    Image(systemName: source.systemImage)
                        .font(.title3)
                        .foregroundStyle(source.color)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.title).font(.body.weight(.medium))
                        Text(source.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(bytes > 0 ? ByteFormat.string(bytes) : model.valueText(for: source, bytes: bytes, empty: "Nothing to free"))
                        .font(bytes > 0 ? .title3.weight(.semibold) : .callout)
                        .foregroundStyle(bytes > 0 ? .primary : .secondary)
                        .monospacedDigit()
                    Button("Review") { model.selectedSection = source.section }
                }
            }
        }
    }

    /// Largest first: the user's next best action is always at the top.
    private var sortedSources: [(SpaceSource, Int64)] {
        model.reclaimable.sorted { $0.1 > $1.1 }
    }
}

// MARK: Caches

struct CachesPage: View {
    @Bindable var model: AppModel

    var body: some View {
        let caches = model.caches
        Page {
            PageHeader(
                title: "Developer caches",
                subtitle: "Shared caches of package managers, browsers for testing and Xcode. Tools download or rebuild them when needed. Items marked “user data” are never cleaned.",
                value: caches.report.map { ByteFormat.string($0.safeReclaimableBytes) },
                valueCaption: caches.report.map { "safe to clean of \(ByteFormat.string($0.totalBytes))" }
            )
            Card {
                if caches.report == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Measuring caches…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
                CachesView(model: caches, showsHeader: false, listMaxHeight: nil)
            }
        }
    }
}

// MARK: Docker

struct DockerPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            PageHeader(
                title: "Docker",
                subtitle: "Images, build cache and containers nobody uses, plus volumes left behind by removed containers. Named volumes may hold databases, so they are backed up before deletion.",
                value: model.dockerReport.flatMap { $0.available ? ByteFormat.string($0.safeReclaimableBytes) : nil },
                valueCaption: "safe to remove"
            )
            if let report = model.dockerReport {
                if report.available {
                    Card(title: "Safe to remove", systemImage: "checkmark.shield") {
                        Text("Re-created automatically: images are pulled or rebuilt, caches refill.")
                            .font(.caption).foregroundStyle(.secondary)
                        if report.safeReclaimableBytes == 0 {
                            Text("Nothing to remove right now.").foregroundStyle(.secondary)
                        } else {
                            DockerCleanupView(report: report, scope: .safe, onFinished: { model.scan(priority: .background) })
                        }
                    }
                    if report.dataVolumeBytes > 0 {
                        Card(title: "Volumes that may contain data · \(ByteFormat.string(report.dataVolumeBytes))", systemImage: "cylinder.split.1x2") {
                            Text("No container uses these volumes, but they can hold databases of old projects. Each volume is archived to ~/DiskCareBackups before it is deleted and can be restored later.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            DockerCleanupView(report: report, scope: .dataVolumes, onFinished: { model.scan(priority: .background) })
                        }
                    }
                    Card(title: "Disk usage", systemImage: "chart.bar") {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                            GridRow {
                                Text("Type"); Text("In use"); Text("Size"); Text("Reclaimable")
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(report.categories) { category in
                                GridRow {
                                    Text(category.category.title)
                                    Text("\(category.activeCount) of \(category.totalCount)").foregroundStyle(.secondary)
                                    Text(ByteFormat.string(category.totalBytes)).monospacedDigit()
                                    Text(ByteFormat.string(category.reclaimableBytes)).monospacedDigit()
                                }
                            }
                        }
                    }
                } else {
                    Card {
                        ContentUnavailableView {
                            Label("Docker isn't running", systemImage: "shippingbox")
                        } description: {
                            Text("Start Docker Desktop or OrbStack, then scan again.")
                        } actions: {
                            Button("Scan again") { model.scan() }
                        }
                    }
                }
            } else {
                ProgressView("Checking Docker…")
            }
        }
    }
}

// MARK: Growth & Prevention

struct GrowthPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            PageHeader(
                title: "Growth",
                subtitle: "Folders that grew the most over the last \(model.growth.days) days. DiskCare also watches build folders live and notifies you when one grows fast."
            )
            Card {
                GrowthView(model: model.growth, maxRows: 25)
            }
        }
    }
}

struct DoctorPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            PageHeader(
                title: "Prevention",
                subtitle: "Tool settings that stop the same waste from coming back, e.g. sharing Terraform providers or Rust build output across projects. Fixes show the exact change and back up the file first."
            )
            Card {
                DoctorView(report: model.report, caches: model.caches.report, showsHeader: false, listMaxHeight: nil)
            }
        }
    }
}
