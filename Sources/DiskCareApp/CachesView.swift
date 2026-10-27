import AppKit
import DiskCareCore
import Observation
import SwiftUI

/// State for the developer caches panel: scan, selection and cleanup.
@MainActor
@Observable
final class CachesModel {
    private(set) var report: CacheReport?
    private(set) var isScanning = false
    private(set) var isCleaning = false
    private(set) var lastMessage: String?
    /// Selected entry and item ids (`homebrew`, `playwright/chromium-1228`).
    var selection: Set<String> = []

    /// Read at clean time so it follows the app's "Move to Trash" setting.
    private let moveToTrash: @MainActor () -> Bool
    private let onCleaned: (@MainActor (CacheCleanResult) -> Void)?

    init(moveToTrash: @escaping @MainActor () -> Bool = { false }, onCleaned: (@MainActor (CacheCleanResult) -> Void)? = nil) {
        self.moveToTrash = moveToTrash
        self.onCleaned = onCleaned
    }

    var selectedTargets: [CacheCleanTarget] {
        guard let report else { return [] }
        let ids = selection.filter { report.entry(id: $0) != nil || report.item(id: $0) != nil }
        return (try? CacheCleaner.targets(ids: ids.sorted(), in: report)) ?? []
    }

    var selectedBytes: Int64 { selectedTargets.reduce(0) { $0 + $1.bytes } }

    var usesTrash: Bool { moveToTrash() }

    func scan() {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        Task {
            let report = await CacheScanner.scan()
            self.report = report
            // Drop selections that no longer exist or are no longer cleanable.
            selection = selection.filter { id in
                if let entry = report.entry(id: id) { return entry.isCleanable }
                return report.item(id: id).flatMap { report.entry(id: $0.entryID) }?.safety.isCleanable ?? false
            }
            isScanning = false
        }
    }

    func isSelected(_ id: String) -> Bool { selection.contains(id) }

    func setSelected(_ id: String, _ selected: Bool) {
        if selected { selection.insert(id) } else { selection.remove(id) }
    }

    func selectAllSafe() {
        selection = Set(report?.allSafeIDs ?? [])
    }

    func cleanSelected() {
        let targets = selectedTargets
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        lastMessage = nil
        let mode: CleanupMode = moveToTrash() ? .trash : .delete
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CacheCleaner.clean(targets, mode: mode)
            }.value
            let failed = result.outcomes.filter { !$0.succeeded }
            var message = "Cleaned \(result.outcomes.count - failed.count)/\(result.outcomes.count)"
            if let freed = result.freedBytes, freed > 0 { message += ", +\(ByteFormat.string(freed)) free" }
            if mode == .trash { message += " (empty Trash to reclaim)" }
            if let first = failed.first { message += ". Failed: \(first.target.id) – \(first.error ?? "error")" }
            lastMessage = message
            selection.removeAll()
            isCleaning = false
            onCleaned?(result)
            scan()
        }
    }
}

/// Global developer caches grouped by category, with checkboxes and a confirmed cleanup.
/// User-data caches (models, archives) are listed but can never be selected.
struct CachesView: View {
    @Bindable var model: CachesModel
    var showsHeader = true
    /// nil = no inner scroll view (the host page scrolls).
    var listMaxHeight: CGFloat? = 320
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsHeader { header }
            if let report = model.report {
                if showsHeader { footer } else { footer.padding(.bottom, 4); Divider() }
                let list = VStack(alignment: .leading, spacing: 16) {
                    ForEach(CacheCategory.allCases, id: \.self) { category in
                        let entries = report.entries.filter { $0.category == category && $0.bytes > 0 }
                        if !entries.isEmpty {
                            section(category, entries)
                        }
                    }
                }
                if let listMaxHeight {
                    ScrollView { list }.frame(maxHeight: listMaxHeight)
                } else {
                    list
                }
            } else {
                Text(model.isScanning ? "Measuring caches…" : "Not scanned yet").font(.callout).foregroundStyle(.secondary)
            }
        }
        .task { if model.report == nil { model.scan() } }
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            Button(model.usesTrash ? "Move to Trash" : "Clean", role: .destructive) { model.cleanSelected() }
        } message: {
            Text("Caches are re-downloaded or rebuilt by their tools when needed. Native cleanup commands (brew, pnpm, uv…) are used when installed.")
        }
    }

    private var header: some View {
        HStack {
            Text("Developer caches").font(.headline)
            if let report = model.report {
                Text("\(ByteFormat.string(report.totalBytes)) total, \(ByteFormat.string(report.safeReclaimableBytes)) safe")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isScanning || model.isCleaning { ProgressView().controlSize(.small) }
            Button {
                model.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(model.isScanning || model.isCleaning)
            .help("Measure again")
        }
    }

    private func section(_ category: CacheCategory, _ entries: [CacheEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(entries) { entry in
                CacheEntryRow(entry: entry, model: model)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Select all safe") { model.selectAllSafe() }
                .disabled(model.isCleaning)
            if let message = model.lastMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button {
                confirming = true
            } label: {
                Text(model.isCleaning ? "Cleaning…" : "Clean \(ByteFormat.string(model.selectedBytes))")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedTargets.isEmpty || model.isCleaning || model.isScanning)
        }
    }

    private var confirmTitle: String {
        let targets = model.selectedTargets
        let action = model.usesTrash ? "Move to Trash" : "Clean"
        return "\(action) \(targets.count) caches (\(ByteFormat.string(model.selectedBytes)))?"
    }
}

private struct CacheEntryRow: View {
    let entry: CacheEntry
    @Bindable var model: CachesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Toggle("", isOn: binding(entry.id)).labelsHidden().toggleStyle(.checkbox)
                    .disabled(!entry.isCleanable || model.isCleaning)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(entry.title).lineLimit(1)
                        SafetyBadge(safety: entry.safety)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Text(ByteFormat.string(entry.bytes)).monospacedDigit()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(entry.paths.map { URL(fileURLWithPath: $0) })
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help(entry.paths.map(\.abbreviatingHome).joined(separator: "\n"))
            }
            let items = entry.items.filter { $0.reason != nil }
            if !items.isEmpty {
                DisclosureGroup("\(items.count) old or unused") {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Toggle("", isOn: binding(item.id)).labelsHidden().toggleStyle(.checkbox)
                                .disabled(!entry.safety.isCleanable || model.isCleaning || model.isSelected(entry.id))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text(item.reason ?? "").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteFormat.string(item.bytes)).monospacedDigit()
                        }
                    }
                }
                .font(.caption)
                .padding(.leading, 22)
            }
        }
        .font(.callout)
        .help(entry.note ?? "")
    }

    private var detail: String {
        var parts: [String] = []
        if let days = entry.idleDays() { parts.append(days == 0 ? "used today" : "used \(days)d ago") }
        switch entry.method {
        case .native: parts.append(entry.command ?? "native command")
        case .deleteContents: parts.append("delete contents")
        case .reportOnly: parts.append("report only")
        }
        if let note = entry.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { model.isSelected(id) }, set: { model.setSelected(id, $0) })
    }
}

private struct SafetyBadge: View {
    let safety: CacheSafety

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(color)
    }

    private var label: String {
        switch safety {
        case .safe: "safe"
        case .regenerable: "re-download"
        case .userData: "user data"
        }
    }

    private var color: Color {
        switch safety {
        case .safe: .green
        case .regenerable: .orange
        case .userData: .secondary
        }
    }
}
