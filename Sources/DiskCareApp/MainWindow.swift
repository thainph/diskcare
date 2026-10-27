import AppKit
import DiskCareCore
import SwiftUI

enum MainSection: String, CaseIterable, Identifiable {
    case overview, projects, docker, caches, growth, doctor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects"
        case .docker: "Docker"
        case .caches: "Caches"
        case .growth: "Growth"
        case .doctor: "Doctor"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .projects: "folder"
        case .docker: "shippingbox"
        case .caches: "archivebox"
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
            List(MainSection.allCases, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.systemImage).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            detail(model.selectedSection ?? .overview)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle((model.selectedSection ?? .overview).title)
                .toolbar {
                    ToolbarItem {
                        Button {
                            model.scan()
                        } label: {
                            Label("Scan now", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isScanning || model.isCleaning)
                    }
                }
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    @ViewBuilder
    private func detail(_ section: MainSection) -> some View {
        switch section {
        case .overview: OverviewView(model: model)
        case .projects: ProjectsView(model: model)
        case .docker: DockerSummaryView(report: model.dockerReport, onFinished: { model.scan() })
        case .caches:
            ContentUnavailableView(section.title, systemImage: section.systemImage, description: Text("Coming soon"))
        case .growth: ScrollView { GrowthView(model: model.growth).padding(20) }
        case .doctor: ScrollView { DoctorView(report: model.report).padding(20) }
        }
    }
}

struct OverviewView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 16) {
                    StatTile(title: "Free space", value: model.freeBytes.map(ByteFormat.string) ?? "–",
                             warning: model.isLowOnSpace)
                    StatTile(title: "Regenerable artifacts", value: model.report.map { ByteFormat.string($0.regenerableBytes) } ?? "–")
                    StatTile(title: "Docker reclaimable", value: model.dockerReport.map {
                        $0.available ? ByteFormat.string($0.reclaimableBytes) : "off"
                    } ?? "–")
                }
                if let report = model.report {
                    GroupBox("Artifacts by kind") {
                        VStack(spacing: 4) {
                            ForEach(report.kindSummaries) { summary in
                                HStack {
                                    Text(summary.kind.rawValue)
                                    Text("×\(summary.count)").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(summary.kind.restoreHint).font(.caption).foregroundStyle(.secondary)
                                    Text(ByteFormat.string(summary.bytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                }
                            }
                        }
                        .padding(4)
                    }
                    Text("Scanned \(report.stats.files.formatted()) files in \(String(format: "%.1f", report.stats.durationSeconds))s · roots: \(report.roots.map(\.abbreviatingHome).joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView("Scanning…")
                }
            }
            .padding(20)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var warning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(warning ? .red : .primary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Docker breakdown plus cleanup actions (DockerCleanupView).
struct DockerSummaryView: View {
    let report: DockerReport?
    var onFinished: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let report, report.available {
                    GroupBox("Disk usage") {
                        VStack(spacing: 4) {
                            ForEach(report.categories) { category in
                                HStack {
                                    Text(category.category.title)
                                    Text("\(category.activeCount)/\(category.totalCount) active").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(ByteFormat.string(category.totalBytes)).monospacedDigit().frame(width: 80, alignment: .trailing)
                                    Text(ByteFormat.string(category.reclaimableBytes)).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                }
                            }
                        }
                        .padding(4)
                    }
                    GroupBox("Clean up") {
                        DockerCleanupView(report: report, onFinished: onFinished).padding(4)
                    }
                    GroupBox("Unused volumes by project") {
                        VStack(spacing: 4) {
                            ForEach(report.unusedVolumeGroups) { group in
                                HStack {
                                    Text(group.isAnonymous ? "anonymous" : (group.composeProject ?? "no project"))
                                    if group.volumes.contains(where: \.mayHoldData) {
                                        Image(systemName: "cylinder.split.1x2").foregroundStyle(.orange)
                                            .help("Named volumes may hold database data")
                                    }
                                    Text("×\(group.volumes.count)").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(ByteFormat.string(group.bytes)).monospacedDigit()
                                }
                            }
                        }
                        .padding(4)
                    }
                } else if let report {
                    ContentUnavailableView("Docker not running", systemImage: "shippingbox",
                                           description: Text(report.error ?? ""))
                } else {
                    ProgressView()
                }
            }
            .padding(20)
        }
    }
}
