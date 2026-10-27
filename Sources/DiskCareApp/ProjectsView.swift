import AppKit
import DiskCareCore
import SwiftUI

/// Selectable cleanup plan with a confirmed "Clean" action. Used in the popover and the main window.
struct CleanupPlanView: View {
    @Bindable var model: AppModel
    var maxListHeight: CGFloat? = 220
    @State private var confirmingClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suggested cleanup").font(.headline)
                Text("idle ≥ \(model.settings.idleDays)d").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isScanning { ProgressView().controlSize(.small) }
            }
            let plan = model.plan
            if model.report == nil {
                Text(model.isScanning ? "Scanning…" : "Not scanned yet").foregroundStyle(.secondary).font(.callout)
            } else if plan.isEmpty {
                Text("Nothing idle enough to clean. Lower “idle days” in Settings to see more.")
                    .foregroundStyle(.secondary).font(.callout)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan) { candidate in
                            CandidateRow(candidate: candidate, isSelected: Binding(
                                get: { !model.deselected.contains(candidate.path) },
                                set: { selected in
                                    if selected { model.deselected.remove(candidate.path) } else { model.deselected.insert(candidate.path) }
                                }
                            ))
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)

                HStack {
                    if let message = model.lastCleanupMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button(model.isCleaning ? "Cleaning…" : "Clean \(ByteFormat.string(selectedBytes))") {
                        confirmingClean = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedPlan.isEmpty || model.isCleaning || model.isScanning)
                }
            }
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmingClean) {
            Button(model.settings.moveToTrash ? "Move to Trash" : "Delete", role: .destructive) { model.cleanSelected() }
        } message: {
            Text("Artifacts are rebuilt by their tools (npm/pnpm install, terraform init, cargo build…). Worktrees are removed with `git worktree remove`; their branches are kept.")
        }
    }

    private var selectedBytes: Int64 {
        model.selectedPlan.reduce(0) { $0 + $1.bytes }
    }

    private var confirmTitle: String {
        let action = model.settings.moveToTrash ? "Move to Trash" : "Permanently delete"
        return "\(action) \(model.selectedPlan.count) items (\(ByteFormat.string(selectedBytes)))?"
    }
}

struct CandidateRow: View {
    let candidate: CleanupCandidate
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Toggle("", isOn: $isSelected).labelsHidden().toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                Text(candidate.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(ByteFormat.string(candidate.bytes)).monospacedDigit()
            RevealButton(path: candidate.path)
        }
        .font(.callout)
    }

    /// "project › node_modules", or "name — remove worktree".
    private var title: String {
        let url = URL(fileURLWithPath: candidate.path)
        if candidate.action == .removeWorktree {
            return "\(url.lastPathComponent) — remove worktree"
        }
        return "\(url.deletingLastPathComponent().lastPathComponent) › \(url.lastPathComponent)"
    }
}

struct RevealButton: View {
    let path: String

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .buttonStyle(.borderless)
        .help(path)
    }
}

/// Main-window page: cleanup plan plus a sortable table of every workspace.
struct ProjectsView: View {
    @Bindable var model: AppModel
    @State private var sortOrder = [KeyPathComparator(\WorkspaceRow.artifactBytes, order: .reverse)]

    var body: some View {
        VSplitView {
            CleanupPlanView(model: model, maxListHeight: nil)
                .padding()
                .frame(minHeight: 200)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Workspace", value: \.name) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.name)
                        Text(row.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TableColumn("Artifacts", value: \.artifactBytes) { Text(ByteFormat.string($0.artifactBytes)).monospacedDigit() }
                    .width(80)
                TableColumn("Total", value: \.totalBytes) { Text(ByteFormat.string($0.totalBytes)).monospacedDigit() }
                    .width(80)
                TableColumn("Idle", value: \.idleDays) { Text($0.idleDays == Int.max ? "–" : "\($0.idleDays)d") }
                    .width(50)
                TableColumn("Git", value: \.state)
                    .width(min: 120, ideal: 180)
                TableColumn("") { RevealButton(path: $0.path) }
                    .width(24)
            }
            .frame(minHeight: 200)
        }
    }

    private var rows: [WorkspaceRow] {
        (model.report?.workspaces ?? []).map(WorkspaceRow.init).sorted(using: sortOrder)
    }
}

struct WorkspaceRow: Identifiable {
    let id: String
    let path: String
    let name: String
    let artifactBytes: Int64
    let totalBytes: Int64
    let idleDays: Int
    let state: String

    init(_ workspace: WorkspaceEntry) {
        id = workspace.path
        path = workspace.path
        name = URL(fileURLWithPath: workspace.path).lastPathComponent
        artifactBytes = workspace.artifactBytes
        totalBytes = workspace.totals.bytes
        idleDays = workspace.idleDays() ?? Int.max
        var parts = [workspace.kind.rawValue]
        if let git = workspace.git {
            parts.append(git.branch ?? "?")
            parts.append(git.uncommittedChanges > 0 ? "dirty" : "clean")
            if let merged = git.mergedInto { parts.append("merged→\(merged)") }
        }
        state = parts.joined(separator: " · ")
    }
}
