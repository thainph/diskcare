import Foundation
import Testing
@testable import DiskCareCore

@Suite struct ProgressiveScanTests {
    private func makeTree() throws -> (root: String, a: String, b: String) {
        let root = ScanOptions.normalize(FileManager.default.temporaryDirectory
            .appendingPathComponent("diskcare-progressive-\(UUID().uuidString)").path)
        for project in ["a", "b"] {
            let modules = "\(root)/\(project)/web/node_modules/pkg"
            try FileManager.default.createDirectory(atPath: modules, withIntermediateDirectories: true)
            try Data(count: 50_000).write(to: URL(fileURLWithPath: "\(modules)/index.js"))
            try Data("{}".utf8).write(to: URL(fileURLWithPath: "\(root)/\(project)/web/package.json"))
        }
        return (root, root + "/a", root + "/b")
    }

    @Test func replacingKeepsOtherRootsAndCombiningMatchesFullScan() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: tree.root) }

        let full = DiskAnalyzer.analyze(ScanOptions(roots: [tree.a, tree.b]), inspectGit: false)
        let onlyA = DiskAnalyzer.analyze(ScanOptions(roots: [tree.a]), inspectGit: false)
        let onlyB = DiskAnalyzer.analyze(ScanOptions(roots: [tree.b]), inspectGit: false)

        // Rescanning root A replaces A's artifacts and keeps B's.
        let replaced = full.replacing(root: tree.a, with: onlyA)
        #expect(Set(replaced.artifacts.map(\.path)) == Set(full.artifacts.map(\.path)))
        #expect(replaced.regenerableBytes == full.regenerableBytes)

        let combined = try #require(ScanReport.combining([onlyA, onlyB]))
        #expect(Set(combined.artifacts.map(\.path)) == Set(full.artifacts.map(\.path)))
        #expect(combined.stats.files == full.stats.files)
        #expect(combined.stats.bytes == full.stats.bytes)
    }

    @Test func progressCountsFilesAndDirectories() throws {
        let tree = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: tree.root) }

        let progress = ScanProgress()
        let scan = FileSystemScanner.scan(ScanOptions(roots: [tree.root], priority: .background, progress: progress))
        #expect(progress.files == Int(scan.stats.files))
        #expect(progress.directories == Int(scan.stats.directories))
        #expect(progress.files == 4)
    }
}
