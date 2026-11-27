import AppKit
import DiskCareCore
import Observation
import SwiftUI

/// Runs Docker cleanups off the main thread and keeps a one-line status.
@MainActor
@Observable
final class DockerCleanupModel {
    let backupDirectory: URL
    /// ID of the action currently running, if any.
    private(set) var runningAction: String?
    private(set) var message: String?

    init(backupDirectory: URL = DockerVolumeBackup.defaultDirectory) {
        self.backupDirectory = backupDirectory
    }

    var isRunning: Bool { runningAction != nil }

    func run(_ actionID: String, selection: DockerCleanupSelection, report: DockerReport, onFinished: @escaping () -> Void) {
        guard !isRunning, let socketPath = report.socketPath else { return }
        let plan = DockerCleanupPlanner.plan(report, selection: selection)
        guard !plan.isEmpty else {
            message = L("Nothing to clean.", "Không có gì để dọn.")
            return
        }
        runningAction = actionID
        message = nil
        let directory = backupDirectory
        Task {
            let outcomes = await Task.detached(priority: .userInitiated) {
                DockerCleaner(socketPath: socketPath, backupDirectory: directory).execute(plan)
            }.value
            message = Self.summary(outcomes)
            runningAction = nil
            onFinished()
        }
    }

    private static func summary(_ outcomes: [DockerCleanupOutcome]) -> String {
        let failed = outcomes.filter { !$0.succeeded }
        let reclaimed = outcomes.reduce(Int64(0)) { $0 + $1.reclaimedBytes }
        var text = L("Removed \(outcomes.count - failed.count)/\(outcomes.count), ~\(ByteFormat.string(reclaimed)) freed",
                     "Đã xoá \(outcomes.count - failed.count)/\(outcomes.count), giải phóng ~\(ByteFormat.string(reclaimed))")
        let backups = outcomes.compactMap(\.backupPath).count
        if backups > 0 { text += L(", \(backups) backup\(backups == 1 ? "" : "s") saved", ", đã lưu \(backups) bản sao lưu") }
        if let first = failed.first { text += L(". Failed: \(first.item.label) – \(first.error ?? "error")", ". Lỗi: \(first.item.label) – \(first.error ?? "error")") }
        return text
    }
}

/// Docker cleanup actions for a scanned `DockerReport`. Self-contained: embed it and rescan in `onFinished`.
struct DockerCleanupView: View {
    enum Scope {
        /// Images, build cache, stopped containers, anonymous volumes.
        case safe
        /// Named volumes (backed up before deletion).
        case dataVolumes
        case all
    }

    let report: DockerReport
    var scope: Scope = .all
    /// Called on the main actor after any cleanup finished (successfully or not); trigger a rescan here.
    var onFinished: () -> Void = {}
    @State private var model: DockerCleanupModel
    @State private var pending: PendingAction?

    init(report: DockerReport, scope: Scope = .all, backupDirectory: URL = DockerVolumeBackup.defaultDirectory, onFinished: @escaping () -> Void = {}) {
        self.report = report
        self.scope = scope
        self.onFinished = onFinished
        _model = State(initialValue: DockerCleanupModel(backupDirectory: backupDirectory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !report.available {
                Text(L("Docker is not running", "Docker chưa chạy")).font(.callout).foregroundStyle(.secondary)
            } else {
                if scope != .dataVolumes, imagesAndCacheBytes > 0 || !report.unusedImages.isEmpty {
                    actionRow(
                        title: L("Unused images & build cache", "Image không dùng & build cache"),
                        detail: L("\(report.unusedImages.count) images, \(report.buildCache.records - report.buildCache.inUse) cache records", "\(report.unusedImages.count) image, \(report.buildCache.records - report.buildCache.inUse) bản ghi cache"),
                        bytes: imagesAndCacheBytes,
                        action: .imagesAndCache
                    )
                }
                if scope != .dataVolumes, !report.stoppedContainers.isEmpty {
                    actionRow(
                        title: L("Stopped containers", "Container đã dừng"),
                        detail: L("\(report.stoppedContainers.count) containers", "\(report.stoppedContainers.count) container"),
                        bytes: report.stoppedContainers.reduce(0) { $0 + $1.bytes },
                        action: .containers
                    )
                }
                ForEach(report.unusedVolumeGroups.filter(includes)) { group in
                    actionRow(
                        title: group.isAnonymous ? L("Anonymous volumes", "Volume ẩn danh") : (group.composeProject ?? L("Volumes without project", "Volume không thuộc dự án")),
                        detail: L("\(group.volumes.count) volume\(group.volumes.count == 1 ? "" : "s")", "\(group.volumes.count) volume")
                            + (group.isAnonymous ? L(", scratch data", ", dữ liệu tạm") : L(", may hold data", ", có thể chứa dữ liệu")),
                        bytes: group.bytes,
                        action: .volumes(group)
                    )
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
        }
        .font(.callout)
        .confirmationDialog(
            pending?.title(report) ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(action.confirmLabel, role: .destructive) { run(action) }
        } message: { action in
            Text(action.message(report, backupDirectory: model.backupDirectory))
        }
    }

    private func actionRow(title: String, detail: String, bytes: Int64, action: PendingAction) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if case .volumes(let group) = action, !group.isAnonymous {
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.orange).help(L("Named volumes may hold database data", "Volume có tên có thể chứa dữ liệu database"))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ByteFormat.string(bytes)).monospacedDigit()
            Button {
                pending = action
            } label: {
                if model.runningAction == action.id {
                    ProgressView().controlSize(.small)
                } else {
                    Text(action.buttonLabel)
                }
            }
            .disabled(model.isRunning)
        }
    }

    private func includes(_ group: DockerVolumeGroup) -> Bool {
        switch scope {
        case .safe: group.isAnonymous
        case .dataVolumes: !group.isAnonymous
        case .all: true
        }
    }

    private var imagesAndCacheBytes: Int64 {
        report.unusedImages.reduce(0) { $0 + $1.uniqueBytes } + report.buildCache.reclaimableBytes
    }

    private func run(_ action: PendingAction) {
        pending = nil
        model.run(action.id, selection: action.selection, report: report, onFinished: onFinished)
    }
}

private enum PendingAction: Identifiable {
    case imagesAndCache
    case containers
    case volumes(DockerVolumeGroup)

    var id: String {
        switch self {
        case .imagesAndCache: "images"
        case .containers: "containers"
        case .volumes(let group): group.id
        }
    }

    var selection: DockerCleanupSelection {
        switch self {
        case .imagesAndCache: DockerCleanupSelection(images: true, buildCache: true)
        case .containers: DockerCleanupSelection(containers: true)
        case .volumes(let group):
            // Exact names, not the project, so volumes that appeared after the scan are never included.
            group.isAnonymous
                ? DockerCleanupSelection(anonymousVolumes: true)
                : DockerCleanupSelection(volumes: group.volumes.map(\.name))
        }
    }

    var buttonLabel: String {
        switch self {
        case .imagesAndCache: L("Clean", "Dọn")
        case .containers: L("Remove", "Xoá")
        case .volumes(let group): group.isAnonymous ? L("Delete", "Xoá") : L("Backup & delete", "Sao lưu & xoá")
        }
    }

    var confirmLabel: String {
        switch self {
        case .imagesAndCache: L("Clean images & build cache", "Dọn image & build cache")
        case .containers: L("Remove stopped containers", "Xoá container đã dừng")
        case .volumes(let group): group.isAnonymous ? L("Delete anonymous volumes", "Xoá volume ẩn danh") : L("Back up & delete", "Sao lưu & xoá")
        }
    }

    func title(_ report: DockerReport) -> String {
        switch self {
        case .imagesAndCache:
            L("Remove \(report.unusedImages.count) unused images and prune the build cache?", "Xoá \(report.unusedImages.count) image không dùng và dọn build cache?")
        case .containers:
            L("Remove \(report.stoppedContainers.count) stopped containers?", "Xoá \(report.stoppedContainers.count) container đã dừng?")
        case .volumes(let group):
            group.isAnonymous
                ? L("Delete \(group.volumes.count) anonymous volumes (\(ByteFormat.string(group.bytes)))?", "Xoá \(group.volumes.count) volume ẩn danh (\(ByteFormat.string(group.bytes)))?")
                : L("Delete \(group.volumes.count) volumes of \(group.composeProject ?? "no project") (\(ByteFormat.string(group.bytes)))?",
                    "Xoá \(group.volumes.count) volume của \(group.composeProject ?? "không dự án") (\(ByteFormat.string(group.bytes)))?")
        }
    }

    func message(_ report: DockerReport, backupDirectory: URL) -> String {
        switch self {
        case .imagesAndCache:
            return L("Images are pulled or rebuilt again when needed. Images used by any container are kept.",
                     "Image sẽ được tải hoặc build lại khi cần. Image đang được container dùng sẽ được giữ.")
        case .containers:
            return L("Their writable layers are lost. Compose recreates them on the next `up`.",
                     "Lớp dữ liệu ghi của chúng sẽ mất. Compose tạo lại ở lần `up` tiếp theo.")
        case .volumes(let group) where group.isAnonymous:
            return L("Anonymous volumes hold scratch data of removed containers. They are deleted without backup.",
                     "Volume ẩn danh chứa dữ liệu tạm của container đã xoá. Chúng bị xoá không sao lưu.")
        case .volumes(let group):
            let names = group.volumes.prefix(5).map(\.name).joined(separator: ", ") + (group.volumes.count > 5 ? "…" : "")
            return L("""
            These volumes may contain databases or other data (\(names)). Deleting them loses that data in Docker.
            Each volume is first archived to \(backupDirectory.path.abbreviatingHome)/<name>-<date>.tar.gz and is kept \
            if its backup fails. Restore with `diskcare docker restore <archive>`.
            """, """
            Các volume này có thể chứa database hoặc dữ liệu khác (\(names)). Xoá sẽ mất dữ liệu đó trong Docker.
            Mỗi volume được nén vào \(backupDirectory.path.abbreviatingHome)/<tên>-<ngày>.tar.gz trước, và được giữ lại \
            nếu sao lưu lỗi. Khôi phục bằng `diskcare docker restore <file>`.
            """)
        }
    }
}
