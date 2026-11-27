import AppKit
import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    @Bindable var settings: AppSettings
    let onChange: () -> Void
    private let launchAtLogin = LaunchAtLogin.shared
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LanguagePicker(language: $settings.language)
            }

            Section(L("Folders to scan", "Thư mục cần quét")) {
                ForEach(settings.roots, id: \.self) { root in
                    HStack {
                        Text(root.abbreviatingHome)
                        Spacer()
                        Button(role: .destructive) {
                            settings.roots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(L("Stop scanning this folder", "Ngừng quét thư mục này"))
                        .accessibilityLabel(L("Remove \(root.abbreviatingHome)", "Bỏ \(root.abbreviatingHome)"))
                    }
                }
                Button(L("Add folder…", "Thêm thư mục…"), action: addFolder)
            }

            Section(L("Cleanup suggestions", "Gợi ý dọn dẹp")) {
                Stepper(L("Idle for at least \(settings.idleDays) days", "Không dùng ít nhất \(settings.idleDays) ngày"), value: $settings.idleDays, in: 1...365)
                Stepper(L("Ignore artifacts under \(settings.minimumArtifactMB) MB", "Bỏ qua mục dưới \(settings.minimumArtifactMB) MB"), value: $settings.minimumArtifactMB, in: 1...10_000, step: 50)
                Toggle(L("Suggest removing merged, clean worktrees", "Gợi ý xoá worktree đã merge và không có thay đổi"), isOn: $settings.removeMergedWorktrees)
                Toggle(L("Move to Trash instead of deleting", "Chuyển vào Thùng rác thay vì xoá hẳn"), isOn: $settings.moveToTrash)
            }

            Section(L("Background", "Chạy nền")) {
                Stepper(L("Scan every \(settings.scanIntervalHours) hours", "Quét mỗi \(settings.scanIntervalHours) giờ"), value: $settings.scanIntervalHours, in: 1...48)
                Toggle(L("Launch at login", "Mở cùng máy"), isOn: Binding(get: { launchAtLogin.isEnabled }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Stepper(L("At least \(settings.lowSpaceThresholdGB) GB", "Tối thiểu \(settings.lowSpaceThresholdGB) GB"), value: $settings.lowSpaceThresholdGB, in: 5...500, step: 5)
                Stepper(L("Or \(settings.lowSpacePercent)% of the disk, if larger", "Hoặc \(settings.lowSpacePercent)% dung lượng ổ, nếu lớn hơn"), value: $settings.lowSpacePercent, in: 1...50)
                Stepper(L("Critical below \(settings.criticalSpacePercent)% of the disk", "Nguy cấp khi dưới \(settings.criticalSpacePercent)% dung lượng ổ"), value: $settings.criticalSpacePercent, in: 1...max(1, settings.lowSpacePercent))
            } header: {
                Text(L("Warn when free space is low", "Cảnh báo khi sắp hết dung lượng"))
            } footer: {
                Text(L("Free space is checked every 15 minutes. Warnings repeat at most daily, critical alerts every 6 hours.",
                       "Dung lượng trống được kiểm tra mỗi 15 phút. Cảnh báo lặp lại tối đa mỗi ngày một lần, cảnh báo nguy cấp mỗi 6 giờ."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .id(settings.language)
        .onAppear { launchAtLogin.refresh() }
        .onChange(of: settings.scanIntervalHours) { onChange() }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        panel.message = L("Choose folders that contain your projects", "Chọn các thư mục chứa dự án của bạn")
        panel.prompt = L("Add", "Thêm")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.roots.contains(url.path) {
            settings.roots.append(url.path)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = "\(error.localizedDescription)"
        }
    }
}

/// "Language / Ngôn ngữ": labelled in both languages so it can be found whichever is active.
struct LanguagePicker: View {
    @Binding var language: AppLanguage

    var body: some View {
        Picker("Language / Ngôn ngữ", selection: $language) {
            ForEach(AppLanguage.allCases) { option in
                Text(option.title).tag(option)
            }
        }
    }
}
