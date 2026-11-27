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
                .background(Palette.pageBackground.ignoresSafeArea())
                .navigationTitle((model.selectedSection ?? .overview).title)
                // Each page has its own header: no second title in the toolbar, and a toolbar that
                // floats over the page (glass on macOS 26) instead of a separate strip.
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
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

/// Disk state, where the space is, and the next best actions, safest first.
struct OverviewView: View {
    @Bindable var model: AppModel
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 44

    var body: some View {
        Page {
            if let status = model.scanStatus {
                Card { ScanStatusView(status: status) }
            }
            if let message = model.lowSpaceMessage {
                StatusBanner(message: message + L(" Start with the suggestions below.", " Hãy bắt đầu với các gợi ý bên dưới."), isError: true)
            } else if let forecast = model.forecastText {
                StatusBanner(message: forecast + L(". Start with the suggestions below.", ". Hãy bắt đầu với các gợi ý bên dưới."), isError: true)
            }
            LaunchAtLoginBanner()
            hero
            SpaceBreakdownCard(model: model)
            suggestions
        }
    }

    // MARK: Hero

    private var hero: some View {
        Card {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 28) {
                    gauge
                    heroText.frame(maxWidth: .infinity, alignment: .leading)
                    heroActions.frame(width: 240)
                }
                HStack(spacing: 24) {
                    gauge
                    VStack(alignment: .leading, spacing: 14) {
                        heroText
                        heroActions.frame(maxWidth: 380)
                    }
                }
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 24) { gauge; heroText }
                    heroActions
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("Disk status", "Trạng thái ổ đĩa"))
    }

    @ViewBuilder
    private var gauge: some View {
        if let space = model.space {
            RingGauge(freeBytes: space.availableBytes, totalBytes: space.totalBytes, level: model.spaceLevel)
        } else {
            ProgressView().frame(width: 132, height: 132)
        }
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StatusPill(level: model.spaceLevel)
                if let threshold = model.thresholdText {
                    Text(threshold).font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.freeBytes.map(ByteFormat.string) ?? "–")
                    .font(.system(size: heroSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let total = model.totalBytes {
                    Text(L("free of \(ByteFormat.string(total))", "trống trên \(ByteFormat.string(total))"))
                        .font(.title3).foregroundStyle(.secondary)
                }
            }
            if let detail = heroDetail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .help(L("Purgeable: space macOS frees on demand (snapshots, iCloud copies). Not counted as free.",
                            "Có thể giải phóng: chỗ macOS tự giải phóng khi cần (snapshot, bản sao iCloud). Không tính là trống."))
            }
        }
    }

    /// "+6.2 GB purgeable · Free space is steady". The forecast is left to the banner above.
    private var heroDetail: String? {
        var parts: [String] = []
        if let purgeable = model.purgeableBytes {
            parts.append(L("+\(ByteFormat.string(purgeable)) purgeable", "+\(ByteFormat.string(purgeable)) có thể giải phóng"))
        }
        if model.forecastText == nil, let trend = model.trendText { parts.append(trend) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var heroActions: some View {
        VStack(spacing: 10) {
            Button {
                model.reviewSafeClean()
            } label: {
                Text(safeCleanLabel).frame(maxWidth: .infinity)
            }
            .primaryActionStyle()
            .controlSize(.large)
            .disabled(model.safeCleanBytes == 0 || model.isCleaning)
            Button {
                model.cleanupFilter = .all
                model.selectedSection = .cleanup
            } label: {
                Text(L("Review everything", "Xem tất cả")).frame(maxWidth: .infinity)
            }
            .secondaryActionStyle()
            .controlSize(.large)
            Text(L("Only pure caches. Nothing to rebuild.", "Chỉ dọn cache thuần. Không phải build lại gì."))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var safeCleanLabel: String {
        if model.safeCleanBytes > 0 { return model.safeCleanTitle }
        return model.caches.report == nil ? L("Measuring caches…", "Đang đo cache…") : L("Nothing safe to clean", "Không có gì cần dọn")
    }

    // MARK: Suggestions

    @ViewBuilder
    private var suggestions: some View {
        let items = model.suggestions
        if items.isEmpty {
            Card {
                Label(model.isScanning ? L("Looking for space to free…", "Đang tìm chỗ có thể giải phóng…")
                                       : L("Nothing to suggest right now. Your disk is in good shape.", "Hiện không có gợi ý nào. Ổ đĩa đang ổn."),
                      systemImage: model.isScanning ? "hourglass" : "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(alignment: .top, spacing: 14) {
                ForEach(items) { suggestion in
                    SuggestionCard(suggestion: suggestion) { model.perform(suggestion) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L("Suggestions", "Gợi ý"))
        }
    }
}

/// "Where your space is": one stacked bar for the whole disk, with a legend.
private struct SpaceBreakdownCard: View {
    let model: AppModel

    var body: some View {
        Card {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("Where your space is", "Dung lượng nằm ở đâu")).font(.headline)
                if let space = model.space {
                    let used = ByteFormat.string(max(0, space.totalBytes - space.availableBytes))
                    Text(L("\(used) used", "đã dùng \(used)")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.selectedSection = .insights
                } label: {
                    HStack(spacing: 3) {
                        Text(L("Explain the rest", "Giải thích phần còn lại"))
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.link)
            }
            if let segments = model.spaceBreakdown {
                bar(segments)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 18)], alignment: .leading, spacing: 8) {
                    ForEach(segments) { legend($0) }
                }
                if model.explain.explanation == nil {
                    Text(L("Applications and the rest of your home folder count as “System & not measured” until you explain the rest.",
                           "Ứng dụng và phần còn lại của thư mục nhà được tính vào “Hệ thống & chưa đo” cho tới khi bạn giải thích phần còn lại."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(L("Measuring the disk…", "Đang đo ổ đĩa…")).foregroundStyle(.secondary)
            }
        }
    }

    private func bar(_ segments: [SpaceSegment]) -> some View {
        let total = max(1, segments.reduce(Int64(0)) { $0 + $1.bytes })
        let visible = segments.filter { $0.bytes > 0 }
        return GeometryReader { geometry in
            let gaps = CGFloat(max(0, visible.count - 1)) * 2
            HStack(spacing: 2) {
                ForEach(visible) { segment in
                    swatch(segment)
                        .frame(width: max(1, (geometry.size.width - gaps) * CGFloat(segment.bytes) / CGFloat(total)))
                        .help("\(segment.title) · \(ByteFormat.string(segment.bytes))")
                }
            }
        }
        .frame(height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel(L("Disk usage by category", "Dung lượng theo nhóm"))
        .accessibilityValue(visible.map { "\($0.title) \(ByteFormat.string($0.bytes))" }.joined(separator: ", "))
    }

    private func legend(_ segment: SpaceSegment) -> some View {
        HStack(spacing: 8) {
            swatch(segment)
                .frame(width: 10, height: 10)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(segment.title).lineLimit(1)
            Spacer(minLength: 4)
            Text(ByteFormat.string(segment.bytes)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
        .help(segment.help)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func swatch(_ segment: SpaceSegment) -> some View {
        Rectangle().fill(segment.color)
            .overlay { if segment.isHatched { Hatch() } }
    }
}

/// Diagonal stripes marking unmeasured space.
private struct Hatch: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 6
            }
            context.stroke(path, with: .color(Color.primary.opacity(0.12)), lineWidth: 2)
        }
    }
}

/// One next step: tier badge, size, what it is and the single action.
private struct SuggestionCard: View {
    let suggestion: OverviewSuggestion
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Badge(text: suggestion.tierLabel, color: suggestion.tier.color, systemImage: suggestion.systemImage)
                Spacer(minLength: 8)
                Text(ByteFormat.string(suggestion.bytes)).font(.title3.weight(.bold)).monospacedDigit()
            }
            Text(suggestion.title).font(.headline)
            Text(suggestion.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            actionButton
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentSurface(cornerRadius: Metrics.cardRadius)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionButton: some View {
        let button = Button(suggestion.actionTitle, action: action)
            .accessibilityHint("\(suggestion.title), \(ByteFormat.string(suggestion.bytes))")
        if suggestion.tier == .safe {
            button.primaryActionStyle()
        } else {
            button.secondaryActionStyle()
        }
    }
}

// MARK: Growth & Prevention

struct GrowthPage: View {
    @Bindable var model: AppModel

    var body: some View {
        Page {
            PageHeader(
                title: L("Growth", "Mức tăng"),
                subtitle: L("Folders that grew the most over the last \(model.growth.days) days. DiskCare also watches build folders live and notifies you when one grows fast.",
                            "Các thư mục tăng nhiều nhất trong \(model.growth.days) ngày qua. DiskCare còn theo dõi trực tiếp thư mục build và báo khi có thư mục tăng nhanh.")
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
                title: L("Prevention", "Phòng ngừa"),
                subtitle: L("Tool settings that stop the same waste from coming back, e.g. sharing Terraform providers or Rust build output across projects. Fixes show the exact change and back up the file first.",
                            "Thiết lập công cụ để rác cũ không quay lại, ví dụ dùng chung provider Terraform hay output build Rust giữa các dự án. Mỗi lần sửa đều hiện thay đổi cụ thể và sao lưu file trước.")
            )
            Card(title: L("Checks", "Các mục kiểm tra"), systemImage: "stethoscope") {
                DoctorView(report: model.report, caches: model.caches.report, showsHeader: false, listMaxHeight: nil)
            }
        }
    }
}
