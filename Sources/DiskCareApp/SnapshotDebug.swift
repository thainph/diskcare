import AppKit
import SwiftUI

/// Debug aid: `DiskCare --snapshot <dir>` renders every main-window section to PNG after the
/// first scan (no Screen Recording permission needed since the app draws its own window).
enum SnapshotDebug {
    static var directory: String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--snapshot"),
              CommandLine.arguments.indices.contains(index + 1) else { return nil }
        return CommandLine.arguments[index + 1]
    }

    @MainActor
    static func run(model: AppModel, openMain: () -> Void) async {
        guard let directory else { return }
        while model.report == nil || model.isScanning || model.caches.report == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        openMain()
        try? await Task.sleep(for: .seconds(1))
        for section in MainSection.allCases {
            model.selectedSection = section
            try? await Task.sleep(for: .seconds(3))
            save(window: NSApp.windows.first { $0.identifier?.rawValue.contains(MainWindow.windowID) == true },
                 to: "\(directory)/\(section.rawValue).png")
        }
        // The popover, hosted offscreen at its real width.
        let host = NSHostingView(rootView: MenuContent(model: model))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        save(view: host, to: "\(directory)/popover.png")
    }

    @MainActor
    private static func save(view: NSView, to path: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private static func save(window: NSWindow?, to path: String) {
        guard let view = window?.contentView?.superview ?? window?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
