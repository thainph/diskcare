import AppKit
import DiskCareCore
import SwiftUI

/// Glanceable popover: disk state, one safe primary action and up to three suggestions.
/// Anything that needs a decision opens the main window, where the user reviews each item.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let message = model.lowSpaceMessage {
                StatusBanner(message: message, isError: true)
            } else if let forecast = model.forecastText {
                StatusBanner(message: forecast + ".", isError: true)
            }
            if let status = model.scanStatus {
                ScanStatusView(status: status, compact: true)
            }
            growthAlert
            LaunchAtLoginBanner()
            Button {
                model.reviewSafeClean()
                showMain()
            } label: {
                Text(safeCleanLabel).frame(maxWidth: .infinity)
            }
            .primaryActionStyle()
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(model.safeCleanBytes == 0 || model.isCleaning)
            suggestionList
            footer
        }
        .padding(18)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let space = model.space {
                RingGauge(freeBytes: space.availableBytes, totalBytes: space.totalBytes, level: model.spaceLevel,
                          size: 56, lineWidth: 8, showsLabel: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.freeBytes.map(ByteFormat.string) ?? "–")
                        .font(.title.weight(.bold)).monospacedDigit()
                    Text(L("free", "trống")).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    StatusPill(level: model.spaceLevel)
                    if let total = model.totalBytes {
                        Text(L("of \(ByteFormat.string(total))", "trên \(ByteFormat.string(total))"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                LastScanLabel(model: model)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var safeCleanLabel: String {
        if model.safeCleanBytes > 0 { return model.safeCleanTitle }
        return model.caches.report == nil ? L("Measuring caches…", "Đang đo cache…") : L("Nothing safe to clean", "Không có gì cần dọn")
    }

    @ViewBuilder
    private var suggestionList: some View {
        let suggestions = model.suggestions
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Suggestions", "Gợi ý"))
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 2)
                ForEach(suggestions) { suggestion in
                    SuggestionRow(suggestion: suggestion) { open(suggestion) }
                }
            }
            .padding(6)
            .contentSurface(cornerRadius: 14)
        }
    }

    @ViewBuilder
    private var growthAlert: some View {
        if let alert = model.growth.liveAlerts.first {
            Button {
                openMain(.insights)
            } label: {
                StatusBanner(message: alert.alert.message, isError: true)
            }
            .buttonStyle(.plain)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openMain(model.selectedSection ?? .overview)
            } label: {
                Text(L("Open DiskCare", "Mở DiskCare")).frame(maxWidth: .infinity)
            }
            Button {
                model.scan()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isScanning || model.isCleaning)
            .help(L("Scan now", "Quét ngay"))
            .accessibilityLabel(L("Scan now", "Quét ngay"))
            Button {
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
                dismiss()
            } label: {
                Image(systemName: "gearshape")
            }
            .help(L("Settings", "Cài đặt"))
            .accessibilityLabel(L("Settings", "Cài đặt"))
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help(L("Quit DiskCare", "Thoát DiskCare"))
            .accessibilityLabel(L("Quit DiskCare", "Thoát DiskCare"))
        }
        .secondaryActionStyle()
    }

    /// Clean opens the review sheet; Review goes to Clean up; report-only items to Insights.
    private func open(_ suggestion: OverviewSuggestion) {
        if case .cleanSafely = suggestion.action {
            model.reviewSafeClean()
            showMain()
        } else {
            openMain(suggestion.section)
        }
    }

    private func openMain(_ section: MainSection) {
        model.selectedSection = section
        showMain()
    }

    private func showMain() {
        openWindow(id: MainWindow.windowID)
        NSApp.activate()
        dismiss()
    }
}

/// A suggestion as a menu row: tier (icon and words, not just color), title, size.
private struct SuggestionRow: View {
    let suggestion: OverviewSuggestion
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: suggestion.systemImage)
                    .foregroundStyle(suggestion.tier.color)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title).lineLimit(1)
                    Text(suggestion.tierLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ByteFormat.string(suggestion.bytes)).fontWeight(.semibold).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(suggestion.detail)
        .accessibilityLabel("\(suggestion.title), \(suggestion.tierLabel), \(ByteFormat.string(suggestion.bytes))")
    }
}
