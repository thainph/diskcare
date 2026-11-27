import AppKit
import DiskCareCore
import Observation
import SwiftUI

/// Runs the disk explorer: what fills the disk outside projects and known caches. Report only.
@MainActor
@Observable
final class ExplainModel {
    private(set) var explanation: DiskExplanation?
    private(set) var isRunning = false
    @ObservationIgnored private var progress: ScanProgress?

    func run(_ options: DiskExplorer.Options) async -> DiskExplanation? {
        guard !isRunning else { return nil }
        isRunning = true
        let progress = ScanProgress()
        self.progress = progress
        var options = options
        options.progress = progress
        let result: DiskExplanation = await DiskExplorer.explore(options)
        explanation = result
        isRunning = false
        self.progress = nil
        return result
    }

    func cancel() {
        progress?.cancel()
    }
}

/// Overview card: the largest folders no scan root or cache accounts for.
struct ExplainCard: View {
    @Bindable var model: AppModel

    var body: some View {
        Card(title: "Where is the space?", systemImage: "questionmark.folder") {
            let explain = model.explain
            HStack {
                Text("Finds large folders outside your projects and known caches. Nothing is deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if explain.isRunning {
                    ProgressView().controlSize(.small)
                    Button("Stop") { explain.cancel() }
                } else {
                    Button(explain.explanation == nil ? "Explain disk usage" : "Explain again") {
                        Task { await model.explainDiskUsage(priority: .userInitiated) }
                    }
                }
            }
            if let explanation = explain.explanation {
                ForEach(explanation.unexplained, id: \.path) { row in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.path.abbreviatingHome + (row.isRemainder ? " (other files)" : "")).lineLimit(1).truncationMode(.middle)
                            if row.containsProjects {
                                Text("Contains git repositories").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(ByteFormat.string(row.bytes)).monospacedDigit()
                        if row.containsProjects, !model.settings.roots.contains(row.path) {
                            Button("Add to scan roots") { model.settings.roots.append(row.path) }
                        }
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.path)])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
                Divider()
                Text(summary(explanation)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ explanation: DiskExplanation) -> String {
        var parts: [String] = []
        if explanation.unexplained.isEmpty { parts.append("No folder above 1 GB outside projects and caches.") }
        for source in explanation.outsideHome where source.bytes > 0 { parts.append("\(source.name): \(ByteFormat.string(source.bytes))") }
        if let unaccounted = explanation.unaccountedBytes, unaccounted > 0 {
            parts.append("\(ByteFormat.string(unaccounted)) not accounted for (system files, privacy-protected folders, VM disks inside app containers)")
        }
        if let snapshots = explanation.localSnapshots, snapshots > 0 { parts.append("\(snapshots) local Time Machine snapshots") }
        if !explanation.notReadWithoutFullDiskAccess.isEmpty {
            parts.append("Desktop, Documents, Downloads and media folders need Full Disk Access to be read")
        }
        if explanation.cancelled { parts.append("stopped early: results are partial") }
        return parts.joined(separator: " · ")
    }
}
