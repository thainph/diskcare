import Foundation
import Testing
@testable import DiskCareCore

@Suite struct AppDataTests {
    private let fm = FileManager.default

    private func write(_ path: String, bytes: Int) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    @Test func bigAppFoldersAreListedButNeverCleanable() throws {
        let home = ScanOptions.normalize(fm.temporaryDirectory.appendingPathComponent("diskcare-appdata-\(UUID().uuidString)").path)
        defer { try? fm.removeItem(atPath: home) }
        let support = home + "/Library/Application Support"
        try write(support + "/Chat/db.sqlite", bytes: 40_000)
        try write(support + "/Tiny/prefs", bytes: 100)
        try write(support + "/AddressBook/contacts.db", bytes: 90_000)
        try write(support + "/com.apple.TCC/TCC.db", bytes: 90_000)
        try write(support + "/Code/CachedData/x", bytes: 50_000)

        var appData = CacheCatalog.appData
        #expect(appData.safety == .userData && appData.fallback == .none)
        appData.itemRule = .largeChildren(minimumBytes: 20_000)
        let vscode = CacheDefinition(id: "vscode", title: "VS Code", category: .ide, safety: .safe,
                                     paths: ["~/Library/Application Support/Code/CachedData"])
        let report = CacheScanner.scan(CacheScanner.Options(definitions: [vscode, appData], home: home, resolver: CommandResolver(searchPaths: []), workerCount: 2))

        let entry = try #require(report.entry(id: "app-data"))
        #expect(entry.method == .reportOnly && !entry.isCleanable)
        // Privacy-protected folders are not read; catalogued caches are counted by their own entry.
        #expect(entry.bytes >= 40_000 && entry.bytes < 90_000)
        #expect(entry.items.map(\.name) == ["Chat"])
        #expect(entry.items.allSatisfy { !$0.isCleanable && !$0.isRecommended })
        #expect(!report.allSafeIDs.contains { $0.hasPrefix("app-data") })
        #expect(report.safeReclaimableBytes == report.entry(id: "vscode")?.bytes)
        #expect(throws: CacheCleanError.self) { try CacheCleaner.targets(ids: ["app-data"], in: report) }
        #expect(throws: CacheCleanError.self) { try CacheCleaner.targets(ids: ["app-data/Chat"], in: report) }
    }
}
