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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to DiskCare").font(.title2.weight(.semibold))
                    Text("Keeps an eye on your disk from the menu bar.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Checks free space every 15 minutes and warns before the disk is full.", systemImage: "gauge.with.dots.needle.33percent")
                Label("Rescans your projects and caches in the background to show what grows.", systemImage: "chart.line.uptrend.xyaxis")
                Label("Never deletes anything without you reviewing it first.", systemImage: "checkmark.shield")
            }
            .font(.callout)
            Divider()
            Toggle(isOn: $launchAtLogin) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                    Text("Recommended: warnings only work while DiskCare is running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Next, macOS asks whether DiskCare may send notifications (low disk space, fast-growing folders).")
                .font(.caption).foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(model.settings.hasCompletedWelcome ? "Close" : "Get Started", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
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
            errorMessage = "Could not change launch at login: \(error.localizedDescription)"
        }
        model.requestNotificationPermission()
        model.settings.hasCompletedWelcome = true
        if errorMessage == nil { dismissWindow(id: Self.windowID) }
    }
}
