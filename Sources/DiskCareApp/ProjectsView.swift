import AppKit
import DiskCareCore
import SwiftUI

extension ArtifactKind {
    /// Plain-language name shown in the app (the raw value stays the CLI/JSON identifier).
    var displayName: String {
        switch self {
        case .nodeModules: "Node packages (node_modules)"
        case .jsFrameworkBuild: "Framework build (.next / .nuxt)"
        case .jsToolCache: "JS tool cache (.turbo…)"
        case .jsBuildOutput: "Build output (dist / build)"
        case .terraform: "Terraform providers (.terraform)"
        case .terragruntCache: "Terragrunt cache"
        case .cargoTarget: "Rust build (target)"
        case .pythonVenv: "Python virtualenv"
        case .pythonCache: "Python bytecode cache"
        case .composerVendor: "PHP packages (vendor)"
        case .cocoaPods: "CocoaPods (Pods)"
        case .gradle: "Gradle build"
        case .dartTool: "Dart / Flutter build"
        case .xcodeDerivedData: "Xcode DerivedData"
        case .gitMetadata: "Git metadata"
        }
    }
}

/// Main-window page: what can be cleaned in projects, grouped by project, plus every workspace.
struct ProjectsView: View {
    @Bindable var model: AppModel
    @State private var confirmingClean = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "Project build files",
                    subtitle: "Dependencies and build output of projects you haven't worked on recently. Their tools rebuild them the next time you open the project.",
                    value: ByteFormat.string(model.planBytes),
                    valueCaption: "\(model.plan.count) items suggested"
                )
                if let message = model.lastCleanupMessage {
                    StatusBanner(message: message, isError: message.contains("Failed")) { model.dismissCleanupMessage() }
                }
                suggestions
                Card(title: "All projects", systemImage: "list.bullet") {
                    WorkspacesTable(workspaces: model.report?.workspaces ?? [])
                        .frame(height: 320)
                }
            }
            .padding(24)
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmingClean) {
            Button(model.settings.moveToTrash ? "Move to Trash" : "Delete", role: .destructive) { model.cleanSelected() }
        } message: {
            Text("Projects stay intact; only regenerable folders are removed (reinstall with npm/pnpm install, terraform init, cargo build…). Worktrees are removed with `git worktree remove` and their branches are kept.")
        }
    }

    // MARK: Suggestions

    private var suggestions: some View {
        @Bindable var settings = model.settings
        return Card {
            HStack(spacing: 12) {
                Text("Suggested").font(.headline)
                Stepper(value: $settings.idleDays, in: 1...365) {
                    Text("unused for at least **\(settings.idleDays) days**").font(.callout)
                }
                .help("Only suggest projects without commits, checkouts or edits for this long")
                Spacer()
                if !model.plan.isEmpty {
                    Button("Select all") { model.selectAllPlan() }.buttonStyle(.link)
                    Button("None") { model.selectNoPlan() }.buttonStyle(.link)
                }
                Button(model.isCleaning ? "Cleaning…" : "Clean \(ByteFormat.string(selectedBytes))") {
                    confirmingClean = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedPlan.isEmpty || model.isCleaning || model.isScanning)
            }
            Divider()
            if model.report == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning your projects…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else if model.plan.isEmpty {
                ContentUnavailableView {
                    Label("Nothing to clean", systemImage: "checkmark.seal")
                } description: {
                    Text("No project has been unused for \(model.settings.idleDays) days. Lower the number of days above to see more.")
                }
                .frame(minHeight: 140)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.key) { group in
                        PlanGroupView(group: group, model: model)
                    }
                }
            }
        }
    }

    private var groups: [PlanGroup] {
        let report = model.report
        let workspaces = Dictionary((report?.workspaces ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let grouped = Dictionary(grouping: model.plan) { candidate in
            candidate.workspacePath ?? (candidate.path as NSString).deletingLastPathComponent
        }
        return grouped.map { key, items in
            PlanGroup(key: key, workspace: workspaces[key], items: items.sorted { $0.bytes > $1.bytes })
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private var selectedBytes: Int64 {
        model.selectedPlan.reduce(0) { $0 + $1.bytes }
    }

    private var confirmTitle: String {
        let action = model.settings.moveToTrash ? "Move to Trash" : "Permanently delete"
        return "\(action) \(model.selectedPlan.count) items (\(ByteFormat.string(selectedBytes)))?"
    }
}

struct PlanGroup {
    let key: String
    let workspace: WorkspaceEntry?
    let items: [CleanupCandidate]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// One project: name, state badges and its cleanable folders.
private struct PlanGroupView: View {
    let group: PlanGroup
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(URL(fileURLWithPath: group.key).lastPathComponent).font(.body.weight(.semibold))
                badges
                Spacer()
                Text(ByteFormat.string(group.bytes)).font(.body.weight(.semibold)).monospacedDigit()
            }
            Text(group.key.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            ForEach(group.items) { candidate in
                CandidateRow(candidate: candidate, isSelected: binding(candidate.path))
                    .padding(.leading, 4)
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        let idle = group.items.compactMap(\.idleDays).min()
        Badge(text: idleText(idle), color: .secondary, systemImage: "clock")
        if let workspace = group.workspace {
            if workspace.kind == .worktree { Badge(text: "worktree", color: .indigo) }
            if let git = workspace.git {
                if git.mergedInto != nil { Badge(text: "merged", color: .green, systemImage: "checkmark") }
                if git.uncommittedChanges > 0 { Badge(text: "uncommitted changes", color: .orange, systemImage: "pencil") }
            }
        }
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { !model.deselected.contains(path) },
            set: { selected in
                if selected { model.deselected.remove(path) } else { model.deselected.insert(path) }
            }
        )
    }
}

struct CandidateRow: View {
    let candidate: CleanupCandidate
    @Binding var isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle(isOn: $isSelected) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            .toggleStyle(.checkbox)
            Spacer()
            Text(ByteFormat.string(candidate.bytes)).monospacedDigit()
            RevealButton(path: candidate.path)
        }
        .font(.callout)
    }

    private var title: String {
        if candidate.action == .removeWorktree { return "Whole worktree (git worktree remove)" }
        return candidate.kind?.displayName ?? URL(fileURLWithPath: candidate.path).lastPathComponent
    }

    private var subtitle: String {
        if candidate.action == .removeWorktree { return "Clean and merged · branch is kept" }
        let relative = URL(fileURLWithPath: candidate.path).lastPathComponent
        return [relative, candidate.kind.map { "restore: \($0.restoreHint)" }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct RevealButton: View {
    let path: String

    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Image(systemName: "folder")
        }
        .buttonStyle(.borderless)
        .help("Show in Finder: \(path.abbreviatingHome)")
        .accessibilityLabel("Show in Finder")
    }
}

/// Sortable table of every repository and worktree.
struct WorkspacesTable: View {
    let workspaces: [WorkspaceEntry]
    @State private var sortOrder = [KeyPathComparator(\WorkspaceRow.artifactBytes, order: .reverse)]

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn("Project", value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    Text(row.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn("Build files", value: \.artifactBytes) { Text(ByteFormat.string($0.artifactBytes)).monospacedDigit() }
                .width(90)
            TableColumn("Total", value: \.totalBytes) { Text(ByteFormat.string($0.totalBytes)).monospacedDigit() }
                .width(80)
            TableColumn("Last activity", value: \.idleDays) { Text(idleText($0.idleDays == Int.max ? nil : $0.idleDays)) }
                .width(110)
            TableColumn("Git", value: \.state)
                .width(min: 120, ideal: 200)
            TableColumn("") { RevealButton(path: $0.path) }
                .width(24)
        }
    }

    private var rows: [WorkspaceRow] {
        workspaces.map(WorkspaceRow.init).sorted(using: sortOrder)
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
        var parts = [workspace.kind == .worktree ? "worktree" : "repo"]
        if let git = workspace.git {
            parts.append(git.branch ?? "?")
            if git.uncommittedChanges > 0 { parts.append("uncommitted") }
            if git.mergedInto != nil { parts.append("merged") }
        }
        state = parts.joined(separator: " · ")
    }
}
