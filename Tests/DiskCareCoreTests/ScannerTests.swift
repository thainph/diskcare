import Foundation
import Testing
@testable import DiskCareCore

@Suite struct ScannerTests {
    /// Builds a small fixture tree in a fresh temporary directory.
    private func makeFixture() throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diskcare-tests-\(UUID().uuidString)").path
        let fm = FileManager.default
        func write(_ relative: String, bytes: Int) throws {
            let path = root + "/" + relative
            try fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: bytes).write(to: URL(fileURLWithPath: path))
        }
        try write("web/package.json", bytes: 10)
        try write("web/src/index.ts", bytes: 5_000)
        try write("web/node_modules/a/index.js", bytes: 100_000)
        try write("web/node_modules/b/deep/x.js", bytes: 200_000)
        try write("web/dist/app.js", bytes: 50_000)
        try write("rust/Cargo.toml", bytes: 10)
        try write("rust/target/debug/bin", bytes: 300_000)
        try write("infra/main.tf", bytes: 10)
        try write("infra/.terraform/providers/aws", bytes: 400_000)
        // `dist` without package.json and `target` without Cargo.toml are not artifacts.
        try write("misc/dist/keep.txt", bytes: 1_000)
        try write("misc/target/keep.txt", bytes: 1_000)
        // Hard link: counted once.
        try fm.linkItem(atPath: root + "/web/node_modules/a/index.js", toPath: root + "/web/node_modules/a/link.js")
        return root
    }

    @Test func detectsArtifactsAndSizes() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let tree = FileSystemScanner.scan(ScanOptions(roots: [root]))
        let artifacts = Dictionary(uniqueKeysWithValues: tree.nodes.compactMap { node in
            node.artifact.map { (String(node.path.dropFirst(root.count + 1)), (kind: $0, totals: node.total)) }
        })

        #expect(Set(artifacts.keys) == ["web/node_modules", "web/dist", "rust/target", "infra/.terraform"])
        #expect(artifacts["web/node_modules"]?.kind == .nodeModules)
        #expect(artifacts["web/dist"]?.kind == .jsBuildOutput)
        #expect(artifacts["rust/target"]?.kind == .cargoTarget)
        #expect(artifacts["infra/.terraform"]?.kind == .terraform)

        let nodeModules = try #require(artifacts["web/node_modules"])
        #expect(nodeModules.totals.files == 3)
        #expect(nodeModules.totals.bytes == allocatedSize(root + "/web/node_modules"))
        #expect(nodeModules.totals.hardlinkedBytes > 0)
        #expect(tree.stats.errors == 0)
    }

    @Test func rootTotalMatchesFileManager() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let tree = FileSystemScanner.scan(ScanOptions(roots: [root], workerCount: 4))
        let rootNode = try #require(tree.nodes.first { $0.parent < 0 })
        #expect(rootNode.total.bytes == allocatedSize(root))
        #expect(rootNode.total.files == 12)
    }

    @Test func excludedPathsAreSkipped() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let tree = FileSystemScanner.scan(ScanOptions(roots: [root], excludedPaths: [root + "/web"]))
        #expect(!tree.nodes.contains { $0.path.hasPrefix(root + "/web") })
    }

    @Test func classifiesAmbiguousNamesOnlyWithMarkers() {
        #expect(ArtifactRules.classify(directoryName: "build", parentMarkers: []) == nil)
        #expect(ArtifactRules.classify(directoryName: "build", parentMarkers: .gradleBuild) == .gradle)
        #expect(ArtifactRules.classify(directoryName: "build", parentMarkers: .packageJSON) == .jsBuildOutput)
        #expect(ArtifactRules.classify(directoryName: "vendor", parentMarkers: .packageJSON) == nil)
        #expect(ArtifactRules.classify(directoryName: "node_modules", parentMarkers: []) == .nodeModules)
    }

    @Test func parsesSizes() {
        #expect(ByteFormat.parse("50MB") == 50_000_000)
        #expect(ByteFormat.parse("1.5g") == 1_500_000_000)
        #expect(ByteFormat.parse("abc") == nil)
    }

    /// Reference implementation: allocated size via FileManager, hard links counted once.
    private func allocatedSize(_ path: String) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .linkCountKey, .fileResourceIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: keys) else { return 0 }
        var seen = Set<String>()
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            if (values.linkCount ?? 1) > 1 {
                let identifier = values.fileResourceIdentifier.map { "\($0)" } ?? url.path
                if !seen.insert(identifier).inserted { continue }
            }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
