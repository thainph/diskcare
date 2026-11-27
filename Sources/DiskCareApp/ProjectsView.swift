import AppKit
import DiskCareCore
import SwiftUI

extension ArtifactKind {
    /// Plain-language name shown in the app (the raw value stays the CLI/JSON identifier).
    var displayName: String {
        switch self {
        case .nodeModules: L("Node packages (node_modules)", "Gói Node (node_modules)")
        case .jsFrameworkBuild: L("Framework build (.next / .nuxt)", "Build framework (.next / .nuxt)")
        case .jsToolCache: L("JS tool cache (.turbo…)", "Cache công cụ JS (.turbo…)")
        case .jsBuildOutput: L("Build output (dist / build)", "Output build (dist / build)")
        case .terraform: L("Terraform providers (.terraform)", "Provider Terraform (.terraform)")
        case .terragruntCache: L("Terragrunt cache", "Cache Terragrunt")
        case .cargoTarget: L("Rust build (target)", "Build Rust (target)")
        case .pythonVenv: L("Python virtualenv", "Virtualenv Python")
        case .pythonCache: L("Python bytecode cache", "Cache bytecode Python")
        case .composerVendor: L("PHP packages (vendor)", "Gói PHP (vendor)")
        case .cocoaPods: "CocoaPods (Pods)"
        case .gradle: L("Gradle build", "Build Gradle")
        case .dartTool: L("Dart / Flutter build", "Build Dart / Flutter")
        case .xcodeDerivedData: "Xcode DerivedData"
        case .cleanupLeftover: L("Unfinished DiskCare cleanup", "Lần dọn dở của DiskCare")
        case .gitMetadata: L("Git metadata", "Dữ liệu Git")
        }
    }
}

struct PlanGroup {
    let key: String
    let workspace: WorkspaceEntry?
    let items: [CleanupCandidate]
    var bytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
}

/// One project: name, state badges and its cleanable folders.
struct PlanGroupView: View {
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
                if git.mergedInto != nil { Badge(text: L("merged", "đã merge"), color: .green, systemImage: "checkmark") }
                if git.uncommittedChanges > 0 { Badge(text: L("uncommitted changes", "chưa commit"), color: .orange, systemImage: "pencil") }
            }
        }
    }

    private func binding(_ path: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedPlanPaths.contains(path) },
            set: { selected in
                if selected { model.selectedPlanPaths.insert(path) } else { model.selectedPlanPaths.remove(path) }
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
        if candidate.action == .removeWorktree { return L("Whole worktree (git worktree remove)", "Cả worktree (git worktree remove)") }
        return candidate.kind?.displayName ?? URL(fileURLWithPath: candidate.path).lastPathComponent
    }

    private var subtitle: String {
        if candidate.action == .removeWorktree { return L("Clean and merged · branch is kept", "Sạch và đã merge · nhánh được giữ") }
        let relative = URL(fileURLWithPath: candidate.path).lastPathComponent
        return [relative, candidate.kind.map { L("restore: \($0.restoreHint)", "khôi phục: \($0.restoreHint)") }].compactMap { $0 }.joined(separator: " · ")
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
        .help(L("Show in Finder: \(path.abbreviatingHome)", "Mở trong Finder: \(path.abbreviatingHome)"))
        .accessibilityLabel(L("Show in Finder", "Mở trong Finder"))
    }
}

/// Sortable table of every repository and worktree.
struct WorkspacesTable: View {
    let workspaces: [WorkspaceEntry]
    @State private var sortOrder = [KeyPathComparator(\WorkspaceRow.artifactBytes, order: .reverse)]

    var body: some View {
        Table(rows, sortOrder: $sortOrder) {
            TableColumn(L("Project", "Dự án"), value: \.name) { row in
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.name)
                    Text(row.path.abbreviatingHome).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            TableColumn(L("Build files", "File build"), value: \.artifactBytes) { Text(ByteFormat.string($0.artifactBytes)).monospacedDigit() }
                .width(90)
            TableColumn(L("Total", "Tổng"), value: \.totalBytes) { Text(ByteFormat.string($0.totalBytes)).monospacedDigit() }
                .width(80)
            TableColumn(L("Last activity", "Hoạt động gần nhất"), value: \.idleDays) { Text(idleText($0.idleDays == Int.max ? nil : $0.idleDays)) }
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
