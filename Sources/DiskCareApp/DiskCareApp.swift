import AppKit
import DiskCareCore
import SwiftUI

@main
struct DiskCareApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = ScanModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Label(model.menuTitle, systemImage: "internaldrive")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon even when launched as a bare executable.
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
@Observable
final class ScanModel {
    private(set) var report: ScanReport?
    private(set) var isScanning = false

    // TODO: make roots configurable in settings.
    let roots = ["~/Workspace", "~/Tools", "~/Development"]
        .map { ($0 as NSString).expandingTildeInPath }
        .filter { FileManager.default.fileExists(atPath: $0) }

    var menuTitle: String {
        report.map { ByteFormat.string($0.regenerableBytes) } ?? "DiskCare"
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        let options = ScanOptions(roots: roots)
        Task {
            report = await DiskAnalyzer.analyze(options)
            isScanning = false
        }
    }
}

struct MenuContent: View {
    let model: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let report = model.report {
                Divider()
                kinds(report)
                Divider()
                workspaces(report)
            }
            Divider()
            HStack {
                Button(model.isScanning ? "Scanning…" : "Scan now") { model.scan() }
                    .disabled(model.isScanning)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 420)
        .task {
            if model.report == nil { model.scan() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Reclaimable artifacts").font(.headline)
            if let report = model.report {
                Text(ByteFormat.string(report.regenerableBytes))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("\(report.stats.files.formatted()) files scanned in \(String(format: "%.1f", report.stats.durationSeconds))s")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func kinds(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(report.kindSummaries.prefix(6)) { summary in
                HStack {
                    Text(summary.kind.rawValue)
                    Text("×\(summary.count)").foregroundStyle(.secondary)
                    Spacer()
                    Text(ByteFormat.string(summary.bytes)).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    private func workspaces(_ report: ScanReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Largest workspaces").font(.subheadline.weight(.semibold))
            ForEach(report.workspaces.prefix(6)) { workspace in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: workspace.path).lastPathComponent).lineLimit(1)
                        Text(subtitle(workspace)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Text(ByteFormat.string(workspace.artifactBytes)).monospacedDigit()
                }
            }
        }
        .font(.callout)
    }

    private func subtitle(_ workspace: WorkspaceEntry) -> String {
        var parts = [workspace.kind.rawValue]
        if let days = workspace.idleDays() { parts.append("idle \(days)d") }
        if let git = workspace.git {
            parts.append(git.uncommittedChanges > 0 ? "dirty" : "clean")
            if git.mergedInto != nil { parts.append("merged") }
        }
        return parts.joined(separator: " · ")
    }
}
