import Foundation
import Synchronization
import Testing
@testable import DiskCareCore

/// Records requests and answers them from a handler keyed by "METHOD /path".
final class FakeDockerTransport: DockerTransport {
    typealias Handler = @Sendable (DockerRequest) -> (Int, String)?
    private let log = Mutex<[DockerRequest]>([])
    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    var requests: [DockerRequest] { log.withLock { $0 } }
    var calls: [String] { requests.map { "\($0.method.rawValue) \($0.path)" } }

    func send(_ request: DockerRequest) throws -> HTTPResponse {
        log.withLock { $0.append(request) }
        let (status, body) = handler(request) ?? (404, #"{"message":"not found"}"#)
        return HTTPResponse(statusCode: status, reason: "", headers: [:], body: Data(body.utf8))
    }
}

@Suite struct DockerRequestTests {
    @Test func encodesPathAndQuery() {
        let filters = DockerRequest.filters(["volume": ["shop_pgdata"]])
        #expect(filters == #"{"volume":["shop_pgdata"]}"#)
        let request = DockerRequest(.get, "/containers/json", query: [("all", "1"), ("filters", filters)])
        #expect(request.target == "/containers/json?all=1&filters=%7B%22volume%22%3A%5B%22shop_pgdata%22%5D%7D")

        #expect(DockerRequest(.post, "/build/prune", query: [("all", "true")]).target == "/build/prune?all=true")
        // Image references keep slashes and colons in the path.
        #expect(DockerRequest(.delete, "/images/ghcr.io/org/app:1.0").target == "/images/ghcr.io/org/app:1.0")
        #expect(DockerRequest(.delete, "/volumes/a b").target == "/volumes/a%20b")
        #expect(DockerRequest(.get, "/x", query: [("q", "a&b=c+d")]).target == "/x?q=a%26b%3Dc%2Bd")
    }

    @Test func buildsRequestHead() {
        let post = String(decoding: UnixSocketHTTPClient.requestHead(method: "POST", target: "/build/prune?all=true", body: nil, contentType: "application/json", host: "localhost"), as: UTF8.self)
        #expect(post.hasPrefix("POST /build/prune?all=true HTTP/1.1\r\n"))
        #expect(post.contains("Content-Length: 0\r\n"))
        #expect(post.hasSuffix("\r\n\r\n"))

        let body = Data(#"{"Name":"v"}"#.utf8)
        let create = String(decoding: UnixSocketHTTPClient.requestHead(method: "POST", target: "/volumes/create", body: body, contentType: "application/json", host: "localhost"), as: UTF8.self)
        #expect(create.contains("Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"))

        let get = String(decoding: UnixSocketHTTPClient.requestHead(method: "GET", target: "/_ping", body: nil, contentType: "application/json", host: "localhost"), as: UTF8.self)
        #expect(!get.contains("Content-Length"))
    }

    @Test func splitsImageReferences() {
        #expect(DockerVolumeBackup.splitReference("alpine:latest") == ("alpine", "latest"))
        #expect(DockerVolumeBackup.splitReference("busybox") == ("busybox", "latest"))
        #expect(DockerVolumeBackup.splitReference("registry:5000/tools/alpine") == ("registry:5000/tools/alpine", "latest"))
    }

    @Test func demultiplexesLogs() {
        var data = Data([2, 0, 0, 0, 0, 0, 0, 5])
        data.append(Data("oops\n".utf8))
        data.append(Data([1, 0, 0, 0, 0, 0, 0, 2]))
        data.append(Data("ok".utf8))
        #expect(DockerVolumeBackup.demultiplex(data) == "oops\nok")
        #expect(DockerVolumeBackup.demultiplex(Data("plain".utf8)) == "plain")
    }

    @Test func validatesVolumeNames() {
        #expect(throws: Never.self) { try DockerVolumeBackup.validate("shop_pgdata-1.2") }
        #expect(throws: DockerBackupError.self) { try DockerVolumeBackup.validate("../etc") }
        #expect(throws: DockerBackupError.self) { try DockerVolumeBackup.validate("") }
        #expect(throws: DockerBackupError.self) { try DockerVolumeBackup.validate("a/b") }
    }
}

@Suite struct DockerCleanupPlannerTests {
    private func report() throws -> DockerReport {
        let df = try JSONDecoder().decode(SystemDFResponse.self, from: Data(DockerReportTests.legacyFixture.utf8))
        return DockerReport(systemDF: df, version: nil, socketPath: "/tmp/d.sock")
    }

    @Test func emptySelectionPlansNothing() throws {
        #expect(DockerCleanupPlanner.plan(try report(), selection: DockerCleanupSelection()).isEmpty)
    }

    @Test func plansImagesCacheAndContainersInOrder() throws {
        let plan = DockerCleanupPlanner.plan(try report(), selection: DockerCleanupSelection(images: true, buildCache: true, containers: true))
        #expect(plan.items.map(\.action) == [.removeContainer, .removeImage, .removeImage, .pruneBuildCache])
        #expect(plan.items[0].target == "c2")
        // Only unused images; the in-use app:latest is never planned.
        #expect(plan.items.filter { $0.action == .removeImage }.map(\.target) == ["sha256:bbbbbbbbbbbbbbbb", "sha256:cccccccccccccccc"])
        #expect(plan.items[1].estimatedBytes == 400)
        #expect(plan.items[3].estimatedBytes == 3_000)
        #expect(plan.items.allSatisfy { !$0.backup })
    }

    @Test func plansVolumesWithBackupForNamedOnly() throws {
        let hex = String(repeating: "0f", count: 32)
        let selection = DockerCleanupSelection(volumes: ["loose", "live", "missing"], projects: ["shop", "ghost"], anonymousVolumes: true)
        let plan = DockerCleanupPlanner.plan(try report(), selection: selection)
        #expect(plan.items.map(\.target) == ["loose", "shop_pgdata", hex])
        #expect(plan.items.map(\.backup) == [true, true, false])
        #expect(plan.items.map(\.isAnonymousVolume) == [false, false, true])
        // In-use and unknown volumes are reported, never planned.
        #expect(plan.skipped.keys.sorted() == ["live", "missing", "project ghost"])

        let unsafe = DockerCleanupPlanner.plan(try report(), selection: DockerCleanupSelection(projects: ["shop"], skipBackup: true))
        #expect(unsafe.items.map(\.backup) == [false])
    }

    @Test func duplicatesAreCollapsed() throws {
        let plan = DockerCleanupPlanner.plan(try report(), selection: DockerCleanupSelection(volumes: ["shop_pgdata"], projects: ["shop"]))
        #expect(plan.items.map(\.target) == ["shop_pgdata"])
    }

    @Test func unavailableReportPlansNothing() {
        let plan = DockerCleanupPlanner.plan(.unavailable(socketPath: nil, error: "down"), selection: DockerCleanupSelection(images: true))
        #expect(plan.isEmpty)
    }
}

@Suite struct DockerCleanerTests {
    private func volumeItem(_ name: String = "shop_pgdata", backup: Bool = true) -> DockerCleanupItem {
        DockerCleanupItem(action: .removeVolume, target: name, label: name, estimatedBytes: 1_000, backup: backup)
    }

    private func tempDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dc-backup-\(UUID().uuidString.prefix(8))")
    }

    /// A daemon with one unused volume, the helper image present, and a configurable helper exit status.
    private func daemon(helperStatus: Int, writesArchiveTo directory: URL? = nil, volumeUsers: String = "[]") -> FakeDockerTransport {
        FakeDockerTransport { request in
            switch (request.method, request.path) {
            case (.get, "/volumes/shop_pgdata"): return (200, #"{"Name":"shop_pgdata","Driver":"local","Labels":{"com.docker.compose.project":"shop"}}"#)
            case (.get, "/containers/json"): return (200, volumeUsers)
            case (.get, "/images/alpine:latest/json"): return (200, #"{"Id":"sha256:alpine"}"#)
            case (.post, "/containers/create"):
                // Simulate tar writing the partial archive through the bind mount.
                if let directory, let body = request.body,
                   let config = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let command = config["Cmd"] as? [String], let target = command.first(where: { $0.hasPrefix("/backup/") }) {
                    let name = String(target.dropFirst("/backup/".count))
                    FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data("tgz".utf8))
                }
                return (201, #"{"Id":"helper1"}"#)
            case (.post, "/containers/helper1/start"): return (204, "")
            case (.post, "/containers/helper1/wait"): return (200, #"{"StatusCode":\#(helperStatus)}"#)
            case (.get, "/containers/helper1/logs"): return (200, "tar: disk full")
            case (.delete, "/containers/helper1"): return (204, "")
            case (.delete, "/volumes/shop_pgdata"): return (204, "")
            default: return nil
            }
        }
    }

    @Test func volumeIsKeptWhenBackupContainerFails() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = daemon(helperStatus: 1)
        let cleaner = DockerCleaner(transport: transport, backup: DockerVolumeBackup(transport: transport, directory: directory))

        let outcome = cleaner.execute(volumeItem())
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("backup failed") == true)
        #expect(outcome.error?.contains("tar: disk full") == true)
        #expect(!transport.calls.contains("DELETE /volumes/shop_pgdata"))
        // The helper container is always cleaned up.
        #expect(transport.calls.contains("DELETE /containers/helper1"))
    }

    @Test func volumeIsKeptWhenArchiveIsCorrupt() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = daemon(helperStatus: 0, writesArchiveTo: directory)
        var backup = DockerVolumeBackup(transport: transport, directory: directory)
        backup.verifyArchive = { url in throw DockerBackupError.archiveCorrupt(path: url.path, detail: "truncated") }
        let outcome = DockerCleaner(transport: transport, backup: backup).execute(volumeItem())

        #expect(!outcome.succeeded)
        #expect(!transport.calls.contains("DELETE /volumes/shop_pgdata"))
        // No half-written archive is left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func volumeIsKeptWithoutBackupLocation() {
        let transport = daemon(helperStatus: 0)
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(volumeItem())
        #expect(!outcome.succeeded)
        #expect(!transport.calls.contains("DELETE /volumes/shop_pgdata"))
    }

    @Test func volumeIsDeletedAfterSuccessfulBackup() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = daemon(helperStatus: 0, writesArchiveTo: directory)
        var backup = DockerVolumeBackup(transport: transport, directory: directory)
        backup.verifyArchive = { _ in }
        let outcome = DockerCleaner(transport: transport, backup: backup).execute(volumeItem())

        #expect(outcome.succeeded, "\(outcome.error ?? "")")
        let path = try #require(outcome.backupPath)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(path.hasSuffix(".tar.gz") && URL(fileURLWithPath: path).lastPathComponent.hasPrefix("shop_pgdata-"))
        #expect(DockerVolumeBackup.metadata(for: URL(fileURLWithPath: path))?.labels["com.docker.compose.project"] == "shop")
        #expect(transport.calls.last == "DELETE /volumes/shop_pgdata")
        // Usage is re-checked before the backup and again right before deleting.
        #expect(transport.calls.filter { $0 == "GET /containers/json" }.count == 2)
        let create = try #require(transport.requests.first { $0.path == "/containers/create" })
        let body = try #require(create.body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let mounts = try #require((body["HostConfig"] as? [String: Any])?["Mounts"] as? [[String: Any]])
        #expect(mounts.first?["Source"] as? String == "shop_pgdata")
        #expect(mounts.first?["ReadOnly"] as? Bool == true)
    }

    @Test func volumeInUseIsSkipped() {
        let transport = daemon(helperStatus: 0, volumeUsers: #"[{"Id":"abc","Names":["/shop-db-1"]}]"#)
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(volumeItem(backup: false))
        #expect(!outcome.succeeded)
        #expect(outcome.error?.contains("shop-db-1") == true)
        #expect(!transport.calls.contains { $0.hasPrefix("DELETE") })
    }

    @Test func skipBackupDeletesDirectly() {
        let transport = daemon(helperStatus: 1)
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(volumeItem(backup: false))
        #expect(outcome.succeeded)
        #expect(!transport.calls.contains("POST /containers/create"))
        #expect(transport.calls.last == "DELETE /volumes/shop_pgdata")
    }

    @Test func runningContainerIsNotRemoved() {
        let transport = FakeDockerTransport { request in
            request.path == "/containers/c2/json" ? (200, #"{"Id":"c2","State":{"Status":"running","Running":true}}"#) : nil
        }
        let item = DockerCleanupItem(action: .removeContainer, target: "c2", label: "db", estimatedBytes: 50)
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(item)
        #expect(!outcome.succeeded)
        #expect(transport.calls == ["GET /containers/c2/json"])
    }

    @Test func stoppedContainerIsRemovedWithoutForce() throws {
        let transport = FakeDockerTransport { request in
            switch (request.method, request.path) {
            case (.get, "/containers/c2/json"): (200, #"{"Id":"c2","State":{"Status":"exited","Running":false}}"#)
            case (.delete, "/containers/c2"): (204, "")
            default: nil
            }
        }
        let item = DockerCleanupItem(action: .removeContainer, target: "c2", label: "db", estimatedBytes: 50)
        #expect(DockerCleaner(transport: transport, backup: nil).execute(item).succeeded)
        #expect(transport.requests.last?.target == "/containers/c2?v=false&force=false")
    }

    @Test func multiTagImageIsUntaggedThenGone() {
        let untagged = Mutex(0)
        let transport = FakeDockerTransport { request in
            switch (request.method, request.path) {
            case (.get, "/images/sha256:bbb/json"):
                // Docker drops the image once its last tag is removed.
                return untagged.withLock { $0 } < 2 ? (200, #"{"Id":"sha256:bbb"}"#) : nil
            case (.get, "/containers/json"): return (200, "[]")
            case (.delete, "/images/old:1"), (.delete, "/images/old:2"):
                untagged.withLock { $0 += 1 }
                return (200, "[]")
            default: return nil
            }
        }
        let item = DockerCleanupItem(action: .removeImage, target: "sha256:bbb", label: "old", estimatedBytes: 400, tags: ["old:1", "old:2"])
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(item)
        #expect(outcome.succeeded, "\(outcome.error ?? "")")
        #expect(transport.calls.filter { $0.hasPrefix("DELETE") } == ["DELETE /images/old:1", "DELETE /images/old:2"])
        let usage = transport.requests.first { $0.path == "/containers/json" }
        #expect(usage?.target == "/containers/json?all=1&filters=%7B%22ancestor%22%3A%5B%22sha256%3Abbb%22%5D%7D")
    }

    @Test func singleTagImageIsDeletedByID() {
        let transport = FakeDockerTransport { request in
            switch (request.method, request.path) {
            case (.get, "/images/sha256:bbb/json"): (200, #"{"Id":"sha256:bbb"}"#)
            case (.get, "/containers/json"): (200, "[]")
            case (.delete, "/images/sha256:bbb"): (200, "[]")
            default: nil
            }
        }
        let item = DockerCleanupItem(action: .removeImage, target: "sha256:bbb", label: "old", estimatedBytes: 400, tags: ["old:1"])
        #expect(DockerCleaner(transport: transport, backup: nil).execute(item).succeeded)
        #expect(transport.requests.last?.target == "/images/sha256:bbb?force=false&noprune=false")
    }

    @Test func imageInUseIsSkipped() {
        let transport = FakeDockerTransport { request in
            switch request.path {
            case "/images/sha256:bbb/json": (200, #"{"Id":"sha256:bbb"}"#)
            case "/containers/json": (200, #"[{"Id":"x","Names":["/web"]}]"#)
            default: nil
            }
        }
        let item = DockerCleanupItem(action: .removeImage, target: "sha256:bbb", label: "old", estimatedBytes: 400, tags: ["old:1"])
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(item)
        #expect(!outcome.succeeded)
        #expect(!transport.calls.contains { $0.hasPrefix("DELETE") })
    }

    @Test func buildCachePruneReportsApiBytes() {
        let transport = FakeDockerTransport { request in
            request.target == "/build/prune?all=true" ? (200, #"{"CachesDeleted":["a","b"],"SpaceReclaimed":12345}"#) : nil
        }
        let item = DockerCleanupItem(action: .pruneBuildCache, target: DockerCleanupPlanner.buildCacheTarget, label: "cache", estimatedBytes: 999)
        let outcome = DockerCleaner(transport: transport, backup: nil).execute(item)
        #expect(outcome.succeeded)
        #expect(outcome.reclaimedBytes == 12_345)
        #expect(!outcome.reclaimedIsEstimate)
    }

    @Test func pullsHelperImageWhenMissing() throws {
        let transport = FakeDockerTransport { request in
            request.target == "/images/create?fromImage=alpine&tag=latest"
                ? (200, "{\"status\":\"Pulling\"}\n{\"error\":\"manifest unknown\"}\n") : nil
        }
        let backup = DockerVolumeBackup(transport: transport, directory: tempDirectory())
        #expect(throws: DockerBackupError.self) { try backup.ensureHelperImage() }
        #expect(transport.calls == ["GET /images/alpine:latest/json", "POST /images/create"])
    }
}
