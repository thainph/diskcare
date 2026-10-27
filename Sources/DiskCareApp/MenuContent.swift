import AppKit
import DiskCareCore
import SwiftUI

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            cleanupSection
            Divider()
            dockerSection
            if let report = model.report {
                Divider()
                DisclosureGroup("All artifacts by kind") { kinds(report) }
                    .font(.callout)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 460)
        .confirmationDialog(confirmTitle, isPresented: $confirmingClean) {
            Button(model.settings.moveToTrash ? "Move to Trash" : "Delete", role: .destructive) { model.cleanSelected() }
        } message: {
            Text("Artifacts are rebuilt by their tools (npm/pnpm install, terraform init, cargo build…). Worktrees are removed with `git worktree remove`; their branches are kept.")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Free space").font(.caption).foregroundStyle(.secondary)
                Text(model.freeBytes.map(ByteFormat.string) ?? "–")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.isLowOnSpace ? .red : .primary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Regenerable artifacts").font(.caption).foregroundStyle(.secondary)
                Text(model.report.map { ByteFormat.string($0.regenerableBytes) } ?? "–")
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
            }
        }
    }

    private var cleanupSection: some View {
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
                .frame(maxHeight: 220)

                HStack {
                    if let message = model.lastCleanupMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button {
                        confirmingClean = true
                    } label: {
                        Text(model.isCleaning ? "Cleaning…" : "Clean \(ByteFormat.string(selectedBytes))")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedPlan.isEmpty || model.isCleaning || model.isScanning)
                }
            }
        }
    }

    private var dockerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Docker").font(.headline)
                Spacer()
                if let docker = model.dockerReport, docker.available {
                    Text("\(ByteFormat.string(docker.reclaimableBytes)) reclaimable").monospacedDigit()
                }
            }
            if let docker = model.dockerReport {
                if !docker.available {
                    Text("Not running").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(docker.categories.filter { $0.totalCount > 0 }) { category in
                        HStack {
                            Text(category.category.title)
                            Text("\(category.activeCount)/\(category.totalCount) active").foregroundStyle(.secondary)
                            Spacer()
                            Text(ByteFormat.string(category.reclaimableBytes)).monospacedDigit()
                        }
                        .font(.callout)
                    }
                    if !docker.unusedVolumeGroups.isEmpty {
                        DisclosureGroup("Unused volumes by project") {
                            ForEach(docker.unusedVolumeGroups) { group in
                                HStack {
                                    Text(group.isAnonymous ? "anonymous" : (group.composeProject ?? "no project"))
                                    if group.volumes.contains(where: \.mayHoldData) {
                                        Image(systemName: "cylinder.split.1x2").help("Named volumes may hold database data")
                                            .foregroundStyle(.orange)
                                    }
                                    Text("×\(group.volumes.count)").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(ByteFormat.string(group.bytes)).monospacedDigit()
                                }
                            }
                        }
                        .font(.callout)
                    }
                }
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        }
    }

    private func kinds(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.kindSummaries) { summary in
                HStack {
                    Text(summary.kind.rawValue)
                    Text("×\(summary.count)").foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormat.string(summary.bytes)).monospacedDigit()
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button(model.isScanning ? "Scanning…" : "Scan now") { model.scan() }
                .disabled(model.isScanning || model.isCleaning)
            if let date = model.lastScanAt {
                Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) + Text(" ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Settings…") {
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
            }
            Button("Quit") { NSApp.terminate(nil) }
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

private struct CandidateRow: View {
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
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help(candidate.path)
        }
        .font(.callout)
    }

    /// "project › node_modules", or "wt/name (worktree)" for worktree removal.
    private var title: String {
        let url = URL(fileURLWithPath: candidate.path)
        if candidate.action == .removeWorktree {
            return "\(url.lastPathComponent) — remove worktree"
        }
        let owner = url.deletingLastPathComponent().lastPathComponent
        return "\(owner) › \(url.lastPathComponent)"
    }
}
