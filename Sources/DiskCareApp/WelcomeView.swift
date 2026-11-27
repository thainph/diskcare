import AppKit
import SwiftUI

/// First-run screen (shown once): launch at login, ticked by default, and notification permission.
/// DiskCare can only warn about a filling disk while it is running.
struct WelcomeView: View {
    static let windowID = "welcome"

    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var launchAtLogin = true
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var settings = model.settings
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Welcome to DiskCare", "Chào mừng đến với DiskCare")).font(.title2.weight(.semibold))
                    Text(L("Keeps an eye on your disk from the menu bar.", "Theo dõi ổ đĩa của bạn ngay trên thanh menu.")).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label(L("Checks free space every 15 minutes and warns before the disk is full.",
                        "Kiểm tra dung lượng trống mỗi 15 phút và cảnh báo trước khi ổ đầy."), systemImage: "gauge.with.dots.needle.33percent")
                Label(L("Rescans your projects and caches in the background to show what grows.",
                        "Quét lại dự án và cache trong nền để cho thấy cái gì đang tăng."), systemImage: "chart.line.uptrend.xyaxis")
                Label(L("Never deletes anything without you reviewing it first.",
                        "Không bao giờ xoá gì khi bạn chưa xem lại."), systemImage: "checkmark.shield")
            }
            .font(.callout)
            Divider()
            LanguagePicker(language: $settings.language)
                .pickerStyle(.menu)
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Launch at login", "Mở cùng máy"))
                    Text(L("Recommended: warnings only work while DiskCare is running.",
                           "Nên bật: cảnh báo chỉ hoạt động khi DiskCare đang chạy."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(L("Next, macOS asks whether DiskCare may send notifications (low disk space, fast-growing folders).",
                   "Tiếp theo, macOS sẽ hỏi DiskCare có được gửi thông báo không (sắp hết dung lượng, thư mục tăng nhanh)."))
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(model.settings.hasCompletedWelcome ? L("Close", "Đóng") : L("Get Started", "Bắt đầu"), action: finish)
                    .primaryActionStyle()
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .id(model.settings.language)
    }

    private func finish() {
        // A second press after an error just closes the window.
        guard !model.settings.hasCompletedWelcome else {
            dismissWindow(id: Self.windowID)
            return
        }
        do {
            if launchAtLogin != LaunchAtLogin.shared.isEnabled { try LaunchAtLogin.shared.set(launchAtLogin) }
        } catch {
            // Not fatal: the in-app warning and Settings offer it again.
            errorMessage = L("Could not change launch at login: \(error.localizedDescription)",
                             "Không đổi được chế độ mở cùng máy: \(error.localizedDescription)")
        }
        model.requestNotificationPermission()
        model.settings.hasCompletedWelcome = true
        if errorMessage == nil { dismissWindow(id: Self.windowID) }
    }
}
