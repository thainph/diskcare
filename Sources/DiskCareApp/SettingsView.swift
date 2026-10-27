import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    static let windowID = "settings"

    @Bindable var settings: AppSettings
    let onChange: () -> Void
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Folders to scan") {
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
                    }
                }
                Button("Add folder…", action: addFolder)
            }

            Section("Cleanup suggestions") {
                Stepper("Idle for at least \(settings.idleDays) days", value: $settings.idleDays, in: 1...365)
                Stepper("Ignore artifacts under \(settings.minimumArtifactMB) MB", value: $settings.minimumArtifactMB, in: 1...10_000, step: 50)
                Toggle("Suggest removing merged, clean worktrees", isOn: $settings.removeMergedWorktrees)
                Toggle("Move to Trash instead of deleting", isOn: $settings.moveToTrash)
            }

            Section("Background") {
                Stepper("Scan every \(settings.scanIntervalHours) hours", value: $settings.scanIntervalHours, in: 1...48)
                Stepper("Warn when free space < \(settings.lowSpaceThresholdGB) GB", value: $settings.lowSpaceThresholdGB, in: 5...500, step: 5)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onChange(of: settings.scanIntervalHours) { onChange() }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.roots.contains(url.path) {
            settings.roots.append(url.path)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
