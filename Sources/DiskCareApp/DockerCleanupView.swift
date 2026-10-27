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
            message = "Nothing to clean."
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
        var text = "Removed \(outcomes.count - failed.count)/\(outcomes.count), ~\(ByteFormat.string(reclaimed)) freed"
        let backups = outcomes.compactMap(\.backupPath).count
        if backups > 0 { text += ", \(backups) backup\(backups == 1 ? "" : "s") saved" }
        if let first = failed.first { text += ". Failed: \(first.item.label) – \(first.error ?? "error")" }
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
                Text("Docker is not running").font(.callout).foregroundStyle(.secondary)
            } else {
                if scope != .dataVolumes, imagesAndCacheBytes > 0 || !report.unusedImages.isEmpty {
                    actionRow(
                        title: "Unused images & build cache",
                        detail: "\(report.unusedImages.count) images, \(report.buildCache.records - report.buildCache.inUse) cache records",
                        bytes: imagesAndCacheBytes,
                        action: .imagesAndCache
                    )
                }
                if scope != .dataVolumes, !report.stoppedContainers.isEmpty {
                    actionRow(
                        title: "Stopped containers",
                        detail: "\(report.stoppedContainers.count) containers",
                        bytes: report.stoppedContainers.reduce(0) { $0 + $1.bytes },
                        action: .containers
                    )
                }
                ForEach(report.unusedVolumeGroups.filter(includes)) { group in
                    actionRow(
                        title: group.isAnonymous ? "Anonymous volumes" : (group.composeProject ?? "Volumes without project"),
                        detail: "\(group.volumes.count) volume\(group.volumes.count == 1 ? "" : "s")"
                            + (group.isAnonymous ? ", scratch data" : ", may hold data"),
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
                Image(systemName: "cylinder.split.1x2").foregroundStyle(.orange).help("Named volumes may hold database data")
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
        case .imagesAndCache: "Clean"
        case .containers: "Remove"
        case .volumes(let group): group.isAnonymous ? "Delete" : "Backup & delete"
        }
    }

    var confirmLabel: String {
        switch self {
        case .imagesAndCache: "Clean images & build cache"
        case .containers: "Remove stopped containers"
        case .volumes(let group): group.isAnonymous ? "Delete anonymous volumes" : "Back up & delete"
        }
    }

    func title(_ report: DockerReport) -> String {
        switch self {
        case .imagesAndCache:
            "Remove \(report.unusedImages.count) unused images and prune the build cache?"
        case .containers:
            "Remove \(report.stoppedContainers.count) stopped containers?"
        case .volumes(let group):
            group.isAnonymous
                ? "Delete \(group.volumes.count) anonymous volumes (\(ByteFormat.string(group.bytes)))?"
                : "Delete \(group.volumes.count) volumes of \(group.composeProject ?? "no project") (\(ByteFormat.string(group.bytes)))?"
        }
    }

    func message(_ report: DockerReport, backupDirectory: URL) -> String {
        switch self {
        case .imagesAndCache:
            return "Images are pulled or rebuilt again when needed. Images used by any container are kept."
        case .containers:
            return "Their writable layers are lost. Compose recreates them on the next `up`."
        case .volumes(let group) where group.isAnonymous:
            return "Anonymous volumes hold scratch data of removed containers. They are deleted without backup."
        case .volumes(let group):
            let names = group.volumes.prefix(5).map(\.name).joined(separator: ", ") + (group.volumes.count > 5 ? "…" : "")
            return """
            These volumes may contain databases or other data (\(names)). Deleting them loses that data in Docker.
            Each volume is first archived to \(backupDirectory.path.abbreviatingHome)/<name>-<date>.tar.gz and is kept \
            if its backup fails. Restore with `diskcare docker restore <archive>`.
            """
        }
    }
}
