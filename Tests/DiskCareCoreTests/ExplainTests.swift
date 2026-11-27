import Foundation
import Testing
@testable import DiskCareCore

@Suite struct ExplainTests {
    private let fm = FileManager.default

    private func write(_ path: String, bytes: Int) throws {
        try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
    }

    @Test func findsLargeFoldersOutsideRootsCachesAndPrivateStores() throws {
        let home = ScanOptions.normalize(fm.temporaryDirectory.appendingPathComponent("diskcare-explain-\(UUID().uuidString)").path)
        defer { try? fm.removeItem(atPath: home) }
        let kb = 1_024
        try write(home + "/.rustup/toolchains/stable/lib.a", bytes: 300 * kb)        // unexplained, depth 2
        try write(home + "/.rustup/settings.toml", bytes: 1 * kb)
        try write(home + "/vm/big.img", bytes: 200 * kb)                             // remainder of a top folder
        try write(home + "/vm/sub/small", bytes: 10 * kb)
        try write(home + "/Archive/old-repo/.git/objects/pack", bytes: 150 * kb)     // has a git repo
        try write(home + "/Workspace/app/node_modules/x", bytes: 500 * kb)           // scan root: already measured
        try write(home + "/.cache/uv/wheel", bytes: 500 * kb)                        // catalogued cache
        try write(home + "/Library/Containers/com.app/Data/blob", bytes: 500 * kb)   // other apps' sandboxes: never read
        try write(home + "/Documents/thesis.pdf", bytes: 500 * kb)                   // privacy folder without FDA

        let explanation = DiskExplorer.explore(DiskExplorer.Options(
            home: home, scanRoots: [home + "/Workspace"], cachePaths: [home + "/.cache/uv"],
            known: [KnownSource(name: "projects", bytes: 1)], fullDiskAccess: false, minimumBytes: 100 * Int64(kb),
            measureOutsideHome: false, countSnapshots: false
        ))
        let rows = Dictionary(uniqueKeysWithValues: explanation.unexplained.map { ($0.path, $0) })
        #expect(Set(rows.keys) == [home + "/.rustup/toolchains", home + "/vm", home + "/Archive/old-repo"])
        #expect(rows[home + "/vm"]?.isRemainder == false, "no listed child: the folder itself")
        #expect(rows[home + "/Archive/old-repo"]?.containsProjects == true)
        #expect(rows[home + "/.rustup/toolchains"]?.containsProjects == false)
        #expect(explanation.unexplained.first?.path == home + "/.rustup/toolchains", "largest first")
        #expect(explanation.exploredBytes < 1_000 * Int64(kb), "roots, caches, containers and Documents are not read")
        #expect(explanation.notReadWithoutFullDiskAccess == [home + "/Documents"])
    }

    @Test func remainderRowCoversWhatChildrenDoNot() throws {
        let home = ScanOptions.normalize(fm.temporaryDirectory.appendingPathComponent("diskcare-explain-\(UUID().uuidString)").path)
        defer { try? fm.removeItem(atPath: home) }
        try write(home + "/data/big/a", bytes: 300_000)
        try write(home + "/data/loose", bytes: 250_000)
        let explanation = DiskExplorer.explore(DiskExplorer.Options(
            home: home, fullDiskAccess: true, minimumBytes: 200_000, measureOutsideHome: false, countSnapshots: false
        ))
        let remainder = try #require(explanation.unexplained.first { $0.path == home + "/data" })
        #expect(remainder.isRemainder && remainder.bytes >= 200_000 && remainder.bytes < 300_000)
    }

    @Test func cancelledExplorationStopsEarly() throws {
        let progress = ScanProgress()
        progress.cancel()
        let explanation = DiskExplorer.explore(DiskExplorer.Options(
            home: fm.temporaryDirectory.path, fullDiskAccess: true, measureOutsideHome: true, countSnapshots: false, progress: progress
        ))
        #expect(explanation.cancelled && explanation.outsideHome.isEmpty)
    }

    @Test func triggerNeedsALargeUnexplainedDrop() {
        let gb: Int64 = 1_000_000_000
        let baseline = ExploreTrigger(availableBytes: 200 * gb, knownBytes: 100 * gb)
        let total = 500 * gb
        #expect(ExploreTrigger.minimumDrop(totalBytes: total) == 10 * gb)
        #expect(ExploreTrigger.minimumDrop(totalBytes: 2_000 * gb) == 40 * gb)
        #expect(!baseline.shouldExplore(availableBytes: 195 * gb, knownBytes: 100 * gb, totalBytes: total), "small drop")
        #expect(baseline.shouldExplore(availableBytes: 170 * gb, knownBytes: 110 * gb, totalBytes: total), "30 GB gone, 10 GB explained")
        #expect(!baseline.shouldExplore(availableBytes: 170 * gb, knownBytes: 120 * gb, totalBytes: total), "two thirds explained")
        #expect(!baseline.shouldExplore(availableBytes: 230 * gb, knownBytes: 90 * gb, totalBytes: total), "space came back")
    }
}
