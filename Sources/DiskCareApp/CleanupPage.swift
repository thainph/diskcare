import AppKit
import DiskCareCore
import SwiftUI

/// Everything DiskCare can clean in one list, grouped by how safe it is: safe caches (preselected
/// by "Clean safely"), things that need a re-download or rebuild (picked by hand), and data that
/// is only reported. One floating bar and one review sheet clean projects and caches together.
struct CleanupPage: View {
    @Bindable var model: AppModel
    @State private var search = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let message = model.lastCleanupMessage {
                        StatusBanner(message: message, isError: message.contains(L("Failed", "Lỗi"))) { model.dismissCleanupMessage() }
                    }
                    if let status = model.scanStatus {
                        Card { ScanStatusView(status: status) }
                    }
                    content
                }
                .padding(Metrics.pagePadding)
                .padding(.bottom, 96)
                .frame(maxWidth: 1080, alignment: .leading)
            }
            if model.cleanupFilter != .docker {
                SelectionBar(model: model)
                    .padding(.horizontal, Metrics.pagePadding)
                    .padding(.bottom, 18)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker(L("Show", "Hiển thị"), selection: $model.cleanupFilter) {
                ForEach(CleanupFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            if model.cleanupFilter == .all || model.cleanupFilter == .projects {
                IdleDaysStepper(settings: model.settings)
            }
            TextField(L("Search", "Tìm kiếm"), text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.cleanupFilter {
        case .docker:
            DockerSection(model: model)
        case .all, .projects, .caches:
            let showProjects = model.cleanupFilter != .caches
            let showCaches = model.cleanupFilter != .projects
            if model.report == nil && model.caches.report == nil {
                Card {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Scanning projects and caches…", "Đang quét dự án và cache…")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            if showCaches {
                TierSection(tier: .safe, entries: entries(in: .safe), model: model, search: search)
            }
            TierSection(tier: .rebuild, entries: showCaches ? entries(in: .rebuild) : [],
                        projectGroups: showProjects ? projectGroups : [], model: model, search: search)
            if showCaches {
                ReportOnlySection(entries: entries(in: .reportOnly).filter { matches($0.title) || $0.paths.contains(where: matches) })
            }
            if model.cleanupFilter == .all {
                DockerSummary(model: model)
            }
            if model.cleanupFilter == .projects {
                Card(title: L("All projects", "Tất cả dự án"), systemImage: "list.bullet") {
                    WorkspacesTable(workspaces: model.report?.workspaces ?? [])
                        .frame(height: 320)
                }
            }
        }
    }

    // MARK: Data

    private func entries(in tier: SafetyTier) -> [CacheEntry] {
        (model.caches.report?.entries ?? [])
            .filter { $0.bytes > 0 && $0.tier == tier }
            .filter { search.isEmpty || matches($0.title) || $0.paths.contains(where: matches) || $0.items.contains { matches($0.name) } }
    }

    private var projectGroups: [PlanGroup] {
        let workspaces = Dictionary((model.report?.workspaces ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: model.plan) { candidate in
            candidate.workspacePath ?? (candidate.path as NSString).deletingLastPathComponent
        }
        return grouped.map { key, items in
            PlanGroup(key: key, workspace: workspaces[key], items: items.sorted { $0.bytes > $1.bytes })
        }
        .filter { search.isEmpty || matches($0.key) }
        .sorted { $0.bytes > $1.bytes }
    }

    private func matches(_ text: String) -> Bool {
        search.isEmpty || text.localizedCaseInsensitiveContains(search)
    }
}

extension CacheEntry {
    /// Safe caches are re-created automatically; regenerable ones need a download or rebuild;
    /// user data and caches DiskCare cannot clean are only reported.
    var tier: SafetyTier {
        if safety == .userData { return .reportOnly }
        if safety == .safe && isCleanable { return .safe }
        if items.contains(where: \.isCleanable) || isCleanable { return safety == .safe ? .safe : .rebuild }
        return .reportOnly
    }
}

/// "Unused for at least N days": how idle a project must be before it is suggested.
private struct IdleDaysStepper: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Stepper(value: $settings.idleDays, in: 1...365) {
            Text(L("Projects idle ≥ \(settings.idleDays) days", "Dự án bỏ ≥ \(settings.idleDays) ngày")).font(.callout)
        }
        .help(L("Only suggest projects without commits, checkouts or edits for this long",
                "Chỉ gợi ý dự án không có commit, checkout hay chỉnh sửa trong khoảng này"))
    }
}

// MARK: Sections

/// One safety tier: header with select-all, cache entries and (for rebuilds) projects.
private struct TierSection: View {
    let tier: SafetyTier
    let entries: [CacheEntry]
    var projectGroups: [PlanGroup] = []
    @Bindable var model: AppModel
    let search: String

    var body: some View {
        if !entries.isEmpty || !projectGroups.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Toggle(isOn: allSelected) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel(L("Select all in \(tier.title)", "Chọn tất cả trong \(tier.title)"))
                    Text(tier.title).font(.headline)
                    Badge(text: tier.badge, color: tier.color)
                    Spacer()
                    Text(summary).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.bottom, 8)
                ForEach(entries) { entry in
                    Divider()
                    CacheEntryRow(entry: entry, caches: model.caches, isCleaning: model.isCleaning)
                }
                ForEach(projectGroups, id: \.key) { group in
                    Divider()
                    PlanGroupView(group: group, model: model).padding(.vertical, 8)
                }
            }
            .padding(18)
            .contentSurface()
        }
    }

    private var summary: String {
        let cacheBytes = entries.reduce(Int64(0)) { total, entry in
            total + (tier == .safe && entry.isCleanable ? entry.bytes : entry.recommendedItems.reduce(0) { $0 + $1.bytes })
        }
        let bytes = cacheBytes + projectGroups.reduce(0) { $0 + $1.bytes }
        let count = entries.count + projectGroups.count
        return tier == .safe
            ? L("\(count) items · \(ByteFormat.string(bytes))", "\(count) mục · \(ByteFormat.string(bytes))")
            : L("suggested · \(ByteFormat.string(bytes))", "gợi ý · \(ByteFormat.string(bytes))")
    }

    /// Ticks every entry (safe tier) or every recommended item and project (rebuild tier).
    private var allSelected: Binding<Bool> {
        let cacheIDs = entries.flatMap { entry -> [String] in
            tier == .safe && entry.isCleanable ? [entry.id] : entry.recommendedItems.filter(\.isCleanable).map(\.id)
        }
        let projectPaths = projectGroups.flatMap { $0.items.map(\.path) }
        return Binding(
            get: {
                !(cacheIDs.isEmpty && projectPaths.isEmpty)
                    && cacheIDs.allSatisfy(model.caches.selection.contains) && projectPaths.allSatisfy(model.selectedPlanPaths.contains)
            },
            set: { selected in
                if selected {
                    model.caches.selection.formUnion(cacheIDs)
                    model.selectedPlanPaths.formUnion(projectPaths)
                } else {
                    model.caches.selection.subtract(cacheIDs)
                    model.selectedPlanPaths.subtract(projectPaths)
                }
            }
        )
    }
}

/// A cache: checkbox when it can be cleaned whole, its parts (versions, build profiles) below.
private struct CacheEntryRow: View {
    let entry: CacheEntry
    @Bindable var caches: CachesModel
    var isCleaning = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle(isOn: binding(entry.id)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!entry.isCleanable || isCleaning)
                    .opacity(entry.isCleanable ? 1 : 0.35)
                    .accessibilityLabel(entry.title)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Text(lastUsed).font(.caption).foregroundStyle(.secondary)
                Text(ByteFormat.string(entry.bytes)).fontWeight(.semibold).monospacedDigit().frame(minWidth: 70, alignment: .trailing)
                RevealButton(path: entry.paths.first ?? "")
            }
            let items = entry.items.filter { $0.reason != nil }
            if !items.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(items) { item in
                        itemRow(item)
                    }
                } label: {
                    Text(L("\(items.count) parts", "\(items.count) phần")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }
        }
        .font(.callout)
        .padding(.vertical, 8)
        .help(entry.note ?? "")
    }

    private func itemRow(_ item: CacheItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(isOn: binding(item.id)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!item.isCleanable || isCleaning || caches.isSelected(entry.id))
                .accessibilityLabel(item.name)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.isPreselectable { Badge(text: SafetyTier.safe.title, color: .green) }
                }
                if let reason = item.reason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                if let blocked = item.blockedReason {
                    Label(L("Not cleanable: \(blocked)", "Không dọn được: \(blocked)"), systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Text(ByteFormat.string(item.bytes)).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 3)
    }

    private var detail: String {
        var parts: [String] = []
        switch entry.method {
        case .native: parts.append(L("runs \(entry.command ?? "its own cleanup")", "chạy \(entry.command ?? "lệnh dọn của công cụ")"))
        case .deleteContents: parts.append(entry.paths.first?.abbreviatingHome ?? "")
        case .reportOnly: parts.append(L("only its parts can be cleaned", "chỉ dọn được từng phần"))
        }
        if let note = entry.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var lastUsed: String {
        guard let days = entry.idleDays() else { return "" }
        return days == 0 ? L("today", "hôm nay") : L("\(days)d ago", "\(days) ngày trước")
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { caches.isSelected(id) }, set: { caches.setSelected(id, $0) })
    }
}

/// User data and caches DiskCare never cleans, collapsed by default.
private struct ReportOnlySection: View {
    let entries: [CacheEntry]
    @State private var expanded = false

    var body: some View {
        if !entries.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        Divider()
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title)
                                Text(entry.note ?? entry.paths.first?.abbreviatingHome ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(ByteFormat.string(entry.bytes)).monospacedDigit()
                            RevealButton(path: entry.paths.first ?? "")
                        }
                        .padding(.vertical, 8)
                        ForEach(entry.items) { item in
                            HStack {
                                Text(item.name).foregroundStyle(.secondary)
                                Spacer()
                                Text(ByteFormat.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                                RevealButton(path: item.path)
                            }
                            .font(.caption)
                            .padding(.leading, 16)
                            .padding(.bottom, 4)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 8)
            } label: {
                HStack(spacing: 10) {
                    Text(SafetyTier.reportOnly.title).font(.headline)
                    Badge(text: SafetyTier.reportOnly.badge, color: .secondary)
                    Text(entries.prefix(3).map(\.title).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Text(ByteFormat.string(entries.reduce(0) { $0 + $1.bytes })).font(.callout.weight(.semibold)).monospacedDigit()
                }
            }
            .padding(18)
            .contentSurface()
        }
    }
}

/// Docker on the All tab: what can go, and a way into the Docker tab.
private struct DockerSummary: View {
    @Bindable var model: AppModel

    var body: some View {
        if let report = model.dockerReport, report.available, report.safeReclaimableBytes + report.dataVolumeBytes > 0 {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").font(.title3).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Docker").font(.headline)
                    Text(L("Unused images, build cache and stopped containers. Volumes are backed up before deletion.",
                           "Image không dùng, build cache và container đã dừng. Volume được sao lưu trước khi xoá."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(ByteFormat.string(report.safeReclaimableBytes)).font(.callout.weight(.semibold)).monospacedDigit()
                Button(L("Open Docker", "Mở Docker")) { model.cleanupFilter = .docker }
                    .secondaryActionStyle()
            }
            .padding(18)
            .contentSurface()
        }
    }
}

/// The Docker tab: its own actions, since volumes need a backup step per group.
private struct DockerSection: View {
    @Bindable var model: AppModel

    var body: some View {
        if let report = model.dockerReport {
            if report.available {
                Card(title: L("Safe to remove", "An toàn để xoá"), systemImage: "checkmark.shield") {
                    Text(L("Re-created automatically: images are pulled or rebuilt, caches refill.",
                           "Tự tạo lại: image được tải hoặc build lại, cache tự đầy lại."))
                        .font(.caption).foregroundStyle(.secondary)
                    if report.safeReclaimableBytes == 0 {
                        Text(L("Nothing to remove right now.", "Hiện không có gì để xoá.")).foregroundStyle(.secondary)
                    } else {
                        DockerCleanupView(report: report, scope: .safe, onFinished: { model.scan(priority: .background) })
                    }
                }
                if report.dataVolumeBytes > 0 {
                    Card(title: L("Volumes that may contain data · \(ByteFormat.string(report.dataVolumeBytes))",
                                  "Volume có thể chứa dữ liệu · \(ByteFormat.string(report.dataVolumeBytes))"),
                         systemImage: "cylinder.split.1x2") {
                        Text(L("No container uses these volumes, but they can hold databases of old projects. Each volume is archived to ~/DiskCareBackups before it is deleted and can be restored later.",
                               "Không container nào dùng các volume này, nhưng chúng có thể chứa database của dự án cũ. Mỗi volume được nén vào ~/DiskCareBackups trước khi xoá và có thể khôi phục sau."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        DockerCleanupView(report: report, scope: .dataVolumes, onFinished: { model.scan(priority: .background) })
                    }
                }
                Card(title: L("Disk usage", "Dung lượng"), systemImage: "chart.bar") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text(L("Type", "Loại")); Text(L("In use", "Đang dùng")); Text(L("Size", "Dung lượng")); Text(L("Reclaimable", "Lấy lại được"))
                        }
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(report.categories) { category in
                            GridRow {
                                Text(category.category.title)
                                Text(L("\(category.activeCount) of \(category.totalCount)", "\(category.activeCount)/\(category.totalCount)")).foregroundStyle(.secondary)
                                Text(ByteFormat.string(category.totalBytes)).monospacedDigit()
                                Text(ByteFormat.string(category.reclaimableBytes)).monospacedDigit()
                            }
                        }
                    }
                }
            } else {
                Card {
                    ContentUnavailableView {
                        Label(L("Docker isn't running", "Docker chưa chạy"), systemImage: "shippingbox")
                    } description: {
                        Text(L("Start Docker Desktop or OrbStack, then scan again.", "Hãy mở Docker Desktop hoặc OrbStack rồi quét lại."))
                    } actions: {
                        Button(L("Scan again", "Quét lại")) { model.scan() }
                    }
                }
            }
        } else {
            ProgressView(L("Checking Docker…", "Đang kiểm tra Docker…"))
        }
    }
}

// MARK: Selection bar

/// Floating glass bar: what is selected, how it will be removed, and the single way to clean it.
private struct SelectionBar: View {
    @Bindable var model: AppModel

    var body: some View {
        @Bindable var settings = model.settings
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectionCount == 0
                     ? L("Nothing selected", "Chưa chọn mục nào")
                     : L("\(model.selectionCount) items · \(ByteFormat.string(model.selectionBytes))",
                         "\(model.selectionCount) mục · \(ByteFormat.string(model.selectionBytes))"))
                    .font(.headline).monospacedDigit()
                Text(model.selectionNeedsRebuild
                     ? L("Includes items that must be downloaded or rebuilt", "Có mục phải tải lại hoặc build lại")
                     : L("All safe: nothing has to be rebuilt", "Tất cả an toàn: không phải build lại gì"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(L("Move to Trash instead", "Chuyển vào Thùng rác"), isOn: $settings.moveToTrash)
                .toggleStyle(.checkbox)
            Button {
                model.isReviewing = true
            } label: {
                Text(model.isCleaning ? L("Cleaning…", "Đang dọn…") : L("Review & clean…", "Xem lại & dọn…"))
                    .padding(.horizontal, 6)
            }
            .controlSize(.large)
            .primaryActionStyle()
            .keyboardShortcut(.defaultAction)
            .disabled(model.selectionCount == 0 || model.isCleaning || model.isScanning)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 20)
        .glassSurface(cornerRadius: 22)
    }
}

extension AppModel {
    /// Anything selected that "Clean safely" would not pick: a project, or a cache that is not safe.
    var selectionNeedsRebuild: Bool {
        if !selectedPlan.isEmpty { return true }
        let safe = Set(caches.report?.allSafeIDs ?? [])
        return caches.selectedTargets.contains { !safe.contains($0.id) }
    }
}

// MARK: Review sheet

/// One confirmation for everything selected. Items that need a rebuild, or more than 20 GB, must be
/// acknowledged with a checkbox; what is shown is exactly what gets cleaned.
struct ReviewSheet: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [CleanupCandidate] = []
    @State private var targets: [CacheCleanTarget] = []
    @State private var acknowledged = false
    @State private var loaded = false

    static let largeCleanupBytes: Int64 = 20_000_000_000

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Clean \(ByteFormat.string(totalBytes))?", "Dọn \(ByteFormat.string(totalBytes))?"))
                    .font(.title2.weight(.bold))
                Text(L("\(projects.count + targets.count) items. Every deletion is written to the audit log.",
                       "\(projects.count + targets.count) mục. Mọi lần xoá đều được ghi vào nhật ký."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                if !safeTargets.isEmpty {
                    line(.safe, title: L("\(safeTargets.count) caches", "\(safeTargets.count) cache"),
                         detail: names(safeTargets.map(\.title)), bytes: safeTargets.reduce(0) { $0 + $1.bytes })
                }
                ForEach(rebuildLines, id: \.title) { item in
                    Divider()
                    line(.rebuild, title: item.title, detail: item.detail, bytes: item.bytes)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .contentSurface(cornerRadius: 14)

            HStack(spacing: 12) {
                Text(L("How", "Cách xoá")).font(.callout).foregroundStyle(.secondary)
                Picker(L("How", "Cách xoá"), selection: $settings.moveToTrash) {
                    Text(L("Delete now", "Xoá ngay")).tag(false)
                    Text(L("Move to Trash", "Vào Thùng rác")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(settings.moveToTrash
                     ? L("Space returns when you empty the Trash.", "Chỉ lấy lại chỗ khi dọn Thùng rác.")
                     : L("Frees space immediately.", "Giải phóng ngay."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if needsAcknowledgement {
                Toggle(isOn: $acknowledged) {
                    Text(acknowledgementText).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            HStack {
                Spacer()
                Button(L("Cancel", "Huỷ")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .secondaryActionStyle()
                Button(L("Clean \(ByteFormat.string(totalBytes))", "Dọn \(ByteFormat.string(totalBytes))"), role: .destructive) {
                    model.cleanReviewed(projects: projects, caches: targets)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .primaryActionStyle()
                .disabled(projects.isEmpty && targets.isEmpty || (needsAcknowledgement && !acknowledged))
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(width: 600)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            projects = model.selectedPlan
            targets = model.caches.selectedTargets
        }
    }

    private func line(_ tier: SafetyTier, title: String, detail: String, bytes: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Badge(text: tier == .safe ? SafetyTier.safe.title : L("Rebuild", "Build lại"), color: tier.color)
            Text(title).lineLimit(1)
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer()
            Text(ByteFormat.string(bytes)).fontWeight(.semibold).monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 9)
    }

    private var safeIDs: Set<String> { Set(model.caches.report?.allSafeIDs ?? []) }

    private var safeTargets: [CacheCleanTarget] { targets.filter { safeIDs.contains($0.id) } }

    private var rebuildLines: [(title: String, detail: String, bytes: Int64)] {
        targets.filter { !safeIDs.contains($0.id) }.map { ($0.title, $0.kind == .entry ? L("whole cache", "toàn bộ cache") : "", $0.bytes) }
            + projects.map { candidate in
                let name = URL(fileURLWithPath: candidate.workspacePath ?? candidate.path).lastPathComponent
                return ("\(name): \(candidate.kind?.displayName ?? URL(fileURLWithPath: candidate.path).lastPathComponent)",
                        candidate.kind.map { L("restore: \($0.restoreHint)", "khôi phục: \($0.restoreHint)") } ?? "", candidate.bytes)
            }
    }

    private var totalBytes: Int64 {
        projects.reduce(0) { $0 + $1.bytes } + targets.reduce(0) { $0 + $1.bytes }
    }

    private var needsAcknowledgement: Bool {
        !rebuildLines.isEmpty || totalBytes > Self.largeCleanupBytes
    }

    private var acknowledgementText: String {
        if rebuildLines.isEmpty {
            return L("I understand this deletes more than \(ByteFormat.string(Self.largeCleanupBytes)).",
                     "Tôi hiểu thao tác này xoá hơn \(ByteFormat.string(Self.largeCleanupBytes)).")
        }
        let list = names(rebuildLines.map(\.title))
        return L("I understand \(list) must be downloaded or rebuilt again.",
                 "Tôi hiểu \(list) sẽ phải tải lại hoặc build lại.")
    }

    private func names(_ all: [String]) -> String {
        all.prefix(3).joined(separator: ", ") + (all.count > 3 ? L(" and \(all.count - 3) more", " và \(all.count - 3) mục khác") : "")
    }
}
