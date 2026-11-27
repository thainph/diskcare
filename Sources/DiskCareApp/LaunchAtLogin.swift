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

    /// Why the last change failed, shown under the toggle.
    private(set) var lastError: String?

    /// For a `Toggle`: `Bindable(LaunchAtLogin.shared).isOn`.
    var isOn: Bool {
        get { isEnabled }
        set {
            do {
                try set(newValue)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
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
                        ? L("Launch at login needs your approval in System Settings › Login Items.",
                            "Mở cùng máy cần bạn cho phép trong Cài đặt hệ thống › Mục đăng nhập.")
                        : L("Launch at login is off: after a restart DiskCare stops checking free space.",
                            "Chưa bật mở cùng máy: sau khi khởi động lại, DiskCare sẽ không kiểm tra dung lượng nữa."))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(launchAtLogin.requiresApproval ? L("Open Settings", "Mở Cài đặt") : L("Turn On", "Bật"), action: fix)
                        .controlSize(.small)
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
