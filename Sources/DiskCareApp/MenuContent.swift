import AppKit
import DiskCareCore
import SwiftUI

/// Compact popover: headline numbers, the cleanup plan and a Docker summary.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            CleanupPlanView(model: model, maxListHeight: 200)
            Divider()
            dockerSummary
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 460)
    }

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

    private var dockerSummary: some View {
        HStack {
            Text("Docker").font(.headline)
            Spacer()
            if let docker = model.dockerReport {
                Text(docker.available ? "\(ByteFormat.string(docker.reclaimableBytes)) reclaimable" : "not running")
                    .foregroundStyle(.secondary)
            }
            Button("Details") { openMain(.docker) }
                .buttonStyle(.link)
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Button(model.isScanning ? "Scanning…" : "Scan now") { model.scan() }
                .disabled(model.isScanning || model.isCleaning)
            if let date = model.lastScanAt {
                Text("updated \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open DiskCare") { openMain(.overview) }
            Button {
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit DiskCare")
        }
    }

    private func openMain(_ section: MainSection) {
        model.selectedSection = section
        openWindow(id: MainWindow.windowID)
        NSApp.activate()
    }
}
