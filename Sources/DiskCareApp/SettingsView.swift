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
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin.isEnabled }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Stepper("At least \(settings.lowSpaceThresholdGB) GB", value: $settings.lowSpaceThresholdGB, in: 5...500, step: 5)
                Stepper("Or \(settings.lowSpacePercent)% of the disk, if larger", value: $settings.lowSpacePercent, in: 1...50)
                Stepper("Critical below \(settings.criticalSpacePercent)% of the disk", value: $settings.criticalSpacePercent, in: 1...max(1, settings.lowSpacePercent))
            } header: {
                Text("Warn when free space is low")
            } footer: {
                Text("Free space is checked every 15 minutes. Warnings repeat at most daily, critical alerts every 6 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { launchAtLogin.refresh() }
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
            try launchAtLogin.set(enabled)
            loginError = nil
        } catch {
            loginError = "\(error.localizedDescription)"
        }
    }
}
