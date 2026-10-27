import AppKit
import DiskCareCore
import SwiftUI

/// Glanceable popover: disk state, how much can be freed and where, one primary action.
/// Destructive actions live in the main window, where the user can review each item.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            diskHeader
            if model.isLowOnSpace {
                StatusBanner(message: "Free space is below \(model.settings.lowSpaceThresholdGB) GB.", isError: true)
            }
            Divider()
            reclaimableSection
            growthAlert
            Button {
                openMain(.overview)
            } label: {
                Text("Review & Clean…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    private var diskHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.freeBytes.map(ByteFormat.string) ?? "–")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.isLowOnSpace ? .red : .primary)
                Text("free").foregroundStyle(.secondary)
                Spacer()
                if let total = model.totalBytes {
                    Text("of \(ByteFormat.string(total))").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let total = model.totalBytes, let free = model.freeBytes {
                DiskUsageBar(totalBytes: total, freeBytes: free, reclaimable: model.reclaimable, height: 10, showsLegend: false)
            }
        }
    }

    private var reclaimableSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("You can free up").font(.headline)
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(ByteFormat.string(model.reclaimableTotal)).font(.headline).monospacedDigit()
                }
            }
            ForEach(model.reclaimable, id: \.0) { source, bytes in
                Button {
                    openMain(source.section)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: source.systemImage)
                            .foregroundStyle(source.color)
                            .frame(width: 18)
                        Text(source.title)
                        Spacer()
                        Text(bytes > 0 ? ByteFormat.string(bytes) : "—")
                            .monospacedDigit()
                            .foregroundStyle(bytes > 0 ? .primary : .secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(source.explanation)
            }
        }
    }

    @ViewBuilder
    private var growthAlert: some View {
        if let alert = model.growth.liveAlerts.first {
            Button {
                openMain(.growth)
            } label: {
                StatusBanner(message: alert.alert.message, isError: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let date = model.lastScanAt {
                Text("Updated \(date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isCleaning)
            .help("Scan now")
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
        .buttonStyle(.borderless)
    }

    private func openMain(_ section: MainSection) {
        model.selectedSection = section
        openWindow(id: MainWindow.windowID)
        NSApp.activate()
    }
}
