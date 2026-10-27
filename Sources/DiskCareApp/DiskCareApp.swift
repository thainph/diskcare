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
            Label(model.menuTitle, systemImage: model.isLowOnSpace ? "externaldrive.badge.exclamationmark" : "internaldrive")
                .labelStyle(.titleAndIcon)
                .task { model.startOnce() }
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon even when launched as a bare executable.
        NSApp.setActivationPolicy(.accessory)
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
