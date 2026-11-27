import DiskCareCore
import Observation
import ServiceManagement
import SwiftUI

/// "Launch at login" through `SMAppService.mainApp`, shared by Settings, the welcome screen and the
/// warning shown when it is off. The status can change in System Settings, so call `refresh()`.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var status = SMAppService.mainApp.status

    var isEnabled: Bool { status == .enabled }

    /// Off in a way the user can fix. `.notFound` (not running from an app bundle, e.g. `swift run`)
    /// is not reported: registering cannot work there.
    var needsAttention: Bool { status == .notRegistered || status == .requiresApproval }

    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// Warning shown in the menu and Overview while launch at login is off.
struct LaunchAtLoginBanner: View {
    private let launchAtLogin = LaunchAtLogin.shared
    @State private var errorMessage: String?

    var body: some View {
        Group { content }
            .onAppear { launchAtLogin.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if launchAtLogin.needsAttention {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(launchAtLogin.requiresApproval
                        ? "Launch at login needs your approval in System Settings › Login Items."
                        : "Launch at login is off: after a restart DiskCare stops checking free space.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(launchAtLogin.requiresApproval ? "Open Settings" : "Turn On", action: fix)
                        .controlSize(.small)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func fix() {
        if launchAtLogin.requiresApproval {
            launchAtLogin.openSystemSettings()
            return
        }
        do {
            try launchAtLogin.set(true)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension ScanStaleness {
    /// Yellow after 2 days, red after 7.
    var color: Color {
        switch self {
        case .fresh, .never: .secondary
        case .aging: .yellow
        case .stale: .red
        }
    }
}

/// "Last full scan: N days ago", colored by age and kept current while shown.
struct LastScanLabel: View {
    let model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(model.lastScanText)
                .font(.caption)
                .foregroundStyle(model.scanStaleness.color)
        }
    }
}
