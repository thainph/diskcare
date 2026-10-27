import AppKit
import DiskCareCore
import SwiftUI

@main
struct DiskCareApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel(settings: AppSettings())

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("DiskCare", id: MainWindow.windowID) {
            MainWindow(model: model)
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.suppressed)

        Window("DiskCare Settings", id: SettingsView.windowID) {
            SettingsView(settings: model.settings, onChange: { model.startSchedule() })
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

extension Notification.Name {
    static let showMainWindow = Notification.Name("DiskCare.showMainWindow")
}

/// Menu bar label. It is always alive, so it also hosts app-level window opening.
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label(model.menuTitle, systemImage: model.isLowOnSpace ? "externaldrive.badge.exclamationmark" : "internaldrive")
            .labelStyle(.titleAndIcon)
            .task {
                model.startOnce()
                await SnapshotDebug.run(model: model) { openWindow(id: MainWindow.windowID) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showMainWindow)) { _ in
                openWindow(id: MainWindow.windowID)
                NSApp.activate()
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon even when launched as a bare executable.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NotificationCenter.default.post(name: .showMainWindow, object: nil)
            }
        }
    }

    /// Opening the app again (Finder, Launchpad, Spotlight) shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showMainWindow, object: nil)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

extension AppModel {
    /// First launch: permissions, schedule and an initial scan.
    func startOnce() {
        guard lastScanAt == nil, !isScanning else { return }
        requestNotificationPermission()
        startSchedule()
        scan()
    }
}
