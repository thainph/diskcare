import AppKit
import DiskCareCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview, projects, caches, docker, growth, doctor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects"
        case .caches: "Caches"
        case .docker: "Docker"
        case .growth: "Growth"
        case .doctor: "Prevention"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .projects: "folder"
        case .caches: "archivebox"
        case .docker: "shippingbox"
        case .growth: "chart.line.uptrend.xyaxis"
        case .doctor: "stethoscope"
        }
    }
}

struct MainWindow: View {
    static let windowID = "main"

    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Label(MainSection.overview.title, systemImage: MainSection.overview.systemImage)
                    .tag(MainSection.overview)
                Section("Free up space") {
                    ForEach(SpaceSource.allCases) { source in
                        sidebarRow(source.section, bytes: bytes(for: source))
                    }
                }
                Section("Keep it clean") {
                    Label(MainSection.growth.title, systemImage: MainSection.growth.systemImage)
                        .badge(model.growth.liveAlerts.count)
                        .tag(MainSection.growth)
                    Label(MainSection.doctor.title, systemImage: MainSection.doctor.systemImage)
                        .tag(MainSection.doctor)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            detail(model.selectedSection ?? .overview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("DiskCare")
                .toolbar {
                    ToolbarItemGroup {
                        if let status = model.scanStatus {
                            Text("\(status.title) (\(status.step)/\(status.totalSteps))")
                                .font(.caption).foregroundStyle(.secondary)
                            ProgressView().controlSize(.small)
                        }
                        Button {
                            model.scan()
                        } label: {
                            Label("Scan now", systemImage: "arrow.clockwise")
                        }
                        .help("Scan projects, caches and Docker again")
                        .disabled(model.isScanning || model.isCleaning)
                    }
                }
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private func sidebarRow(_ section: MainSection, bytes: Int64) -> some View {
        Label(section.title, systemImage: section.systemImage)
            .badge(bytes > 0 ? Text(ByteFormat.string(bytes)).monospacedDigit() : nil)
            .tag(section)
    }

    private func bytes(for source: SpaceSource) -> Int64 {
        model.reclaimable.first { $0.0 == source }?.1 ?? 0
    }

    @ViewBuilder
    private func detail(_ section: MainSection) -> some View {
        switch section {
        case .overview: OverviewView(model: model)
        case .projects: ProjectsView(model: model)
        case .caches: CachesPage(model: model)
        case .docker: DockerPage(model: model)
        case .growth: GrowthPage(model: model)
        case .doctor: DoctorPage(model: model)
        }
    }
}

/// Shared page scaffold: scrollable, consistent padding and spacing.
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .padding(24)
                .frame(maxWidth: 980, alignment: .leading)
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
            if model.isLowOnSpace {
                StatusBanner(message: "Free space is below your \(model.settings.lowSpaceThresholdGB) GB warning threshold. Start with the largest item below.", isError: true)
            }
            diskCard
            reclaimCard
            if !model.growth.liveAlerts.isEmpty || (model.growth.report?.alerts.isEmpty == false) {
                Card(title: "Growing fast", systemImage: "chart.line.uptrend.xyaxis") {
                    GrowthView(model: model.growth, maxRows: 3, showsHeader: false)
                    Button("See growth details") { model.selectedSection = .growth }.buttonStyle(.link)
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
                Spacer()
                if let date = model.lastScanAt {
                    Text("Scanned \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                }
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
                DoctorView(report: model.report, showsHeader: false, listMaxHeight: nil)
            }
        }
    }
}
