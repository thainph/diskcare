import Darwin
import Foundation
import Testing
@testable import DiskCareCore

@Suite struct HTTPResponseParserTests {
    private func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    @Test func parsesContentLength() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\n{\"a\":\"xyz\"}"
        let response = try #require(try HTTPResponseParser.parse(bytes(raw), isComplete: true))
        #expect(response.statusCode == 200)
        #expect(response.reason == "OK")
        #expect(response.headers["content-type"] == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == "{\"a\":\"xyz\"}")
    }

    @Test func waitsForFullContentLengthBody() throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n12345")
        #expect(try HTTPResponseParser.parse(raw, isComplete: false) == nil)
        #expect(throws: HTTPClientError.self) { try HTTPResponseParser.parse(raw, isComplete: true) }
    }

    @Test func ignoresBytesBeyondContentLength() throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOKtrailing")
        let response = try #require(try HTTPResponseParser.parse(raw, isComplete: true))
        #expect(String(decoding: response.body, as: UTF8.self) == "OK")
    }

    @Test func decodesChunkedBody() throws {
        let raw = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "4\r\nWiki\r\n6;ext=1\r\npedia \r\nE\r\nin \r\n\r\nchunks.\r\n0\r\nX-Trailer: 1\r\n\r\n"
        let response = try #require(try HTTPResponseParser.parse(bytes(raw), isComplete: true))
        #expect(String(decoding: response.body, as: UTF8.self) == "Wikipedia in \r\n\r\nchunks.")
    }

    @Test func incompleteChunkedBodyNeedsMoreData() throws {
        let raw = bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi")
        #expect(try HTTPResponseParser.parse(raw, isComplete: false) == nil)
        #expect(throws: HTTPClientError.self) { try HTTPResponseParser.parse(raw, isComplete: true) }
    }

    @Test func rejectsBadChunkSize() {
        let raw = bytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n")
        #expect(throws: HTTPClientError.self) { try HTTPResponseParser.parse(raw, isComplete: true) }
    }

    @Test func readsUntilCloseWithoutFraming() throws {
        let raw = bytes("HTTP/1.0 500 Internal Server Error\r\n\r\noops")
        #expect(try HTTPResponseParser.parse(raw, isComplete: false) == nil)
        let response = try #require(try HTTPResponseParser.parse(raw, isComplete: true))
        #expect(response.statusCode == 500)
        #expect(response.reason == "Internal Server Error")
        #expect(String(decoding: response.body, as: UTF8.self) == "oops")
    }

    @Test func rejectsGarbage() {
        #expect(throws: HTTPClientError.self) { try HTTPResponseParser.parse(bytes("SSH-2.0-OpenSSH\r\n\r\n"), isComplete: true) }
        #expect(throws: HTTPClientError.self) { try HTTPResponseParser.parse([], isComplete: true) }
    }
}

@Suite struct UnixSocketHTTPClientTests {
    /// Serves one connection on a temporary unix socket, replying with `response` (or never, if nil).
    private func withServer(response: String?, _ body: (String) throws -> Void) throws {
        let path = NSTemporaryDirectory() + "dc-\(UUID().uuidString.prefix(8)).sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let utf8 = Array(path.utf8)
            raw.copyBytes(from: utf8)
            raw[utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        try #require(listen(fd, 1) == 0)

        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let client = accept(fd, nil, nil)
            var buffer = [UInt8](repeating: 0, count: 4096)
            _ = recv(client, &buffer, buffer.count, 0)
            if let response {
                let bytes = Array(response.utf8)
                _ = bytes.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
                close(client)
            } else {
                done.wait()
                close(client)
            }
        }
        try body(path)
        done.signal()
    }

    @Test func fetchesChunkedResponseOverUnixSocket() throws {
        let reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n"
        try withServer(response: reply) { path in
            let response = try UnixSocketHTTPClient(socketPath: path, timeout: 2).get("/_ping")
            #expect(response.statusCode == 200)
            #expect(String(decoding: response.body, as: UTF8.self) == "OK")
        }
    }

    @Test func timesOutWhenServerIsSilent() throws {
        try withServer(response: nil) { path in
            let start = Date()
            #expect(throws: HTTPClientError.self) { try UnixSocketHTTPClient(socketPath: path, timeout: 0.3).get("/_ping") }
            #expect(Date().timeIntervalSince(start) < 2)
        }
    }

    @Test func missingSocketFailsFast() {
        let path = NSTemporaryDirectory() + "dc-missing.sock"
        #expect(throws: HTTPClientError.self) { try UnixSocketHTTPClient(socketPath: path).get("/_ping") }
    }

    @Test func missingDaemonReportsUnavailable() {
        var options = DockerScanner.Options(socketPath: NSTemporaryDirectory() + "dc-missing.sock")
        options.probeTimeout = 0.5
        let report = DockerScanner.scan(options)
        #expect(!report.available)
        #expect(report.error != nil)
    }

    /// Hits the real daemon when one is running; otherwise there is nothing to check.
    @Test(.enabled(if: (try? DockerClient.resolveSocketPath()) != nil))
    func liveDaemonIfPresent() throws {
        let report = DockerScanner.scan()
        if report.available {
            #expect(report.categories.count == DockerCategory.allCases.count)
        } else {
            #expect(report.error != nil)
        }
    }
}

@Suite struct DockerReportTests {
    @Test func resolvesSocketPath() throws {
        let home = "/Users/me"
        let exists: (String) -> Bool = { $0 == "/var/run/docker.sock" || $0 == "/Users/me/.orbstack/run/docker.sock" }
        #expect(try DockerClient.resolveSocketPath(environment: [:], home: home, socketExists: exists) == "/Users/me/.orbstack/run/docker.sock")
        #expect(try DockerClient.resolveSocketPath(environment: ["DOCKER_HOST": "unix:///tmp/d.sock"], home: home, socketExists: exists) == "/tmp/d.sock")
        #expect(throws: DockerClientError.self) {
            try DockerClient.resolveSocketPath(environment: ["DOCKER_HOST": "tcp://h:2375"], home: home, socketExists: exists)
        }
        #expect(throws: DockerClientError.self) { try DockerClient.resolveSocketPath(environment: [:], home: home, socketExists: { _ in false }) }
    }

    @Test func buildsReportFromLegacySystemDF() throws {
        let df = try JSONDecoder().decode(SystemDFResponse.self, from: Data(Self.legacyFixture.utf8))
        let report = DockerReport(systemDF: df, version: nil, socketPath: "/tmp/d.sock", finishedAt: ["c2": Date(timeIntervalSince1970: 1_700_000_000)])

        #expect(report.available)
        let images = try #require(report.summary(.images))
        #expect(images.totalCount == 3)
        #expect(images.activeCount == 1)
        #expect(images.totalBytes == 900)
        // In-use image contributes Size - SharedSize = 300 - 100.
        #expect(images.reclaimableBytes == 700)
        #expect(report.unusedImages.map(\.shortID) == ["bbbbbbbbbbbb", "cccccccccccc"])
        #expect(report.unusedImages.last?.isDangling == true)
        #expect(report.unusedImages.first?.uniqueBytes == 400)

        let containers = try #require(report.summary(.containers))
        #expect(containers.totalCount == 2)
        #expect(containers.activeCount == 1)
        #expect(containers.totalBytes == 60)
        #expect(containers.reclaimableBytes == 50)
        let stopped = try #require(report.stoppedContainers.first)
        #expect(report.stoppedContainers.count == 1)
        #expect(stopped.name == "shop-db-1")
        #expect(stopped.composeProject == "shop")
        #expect(stopped.finishedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let volumes = try #require(report.summary(.volumes))
        #expect(volumes.totalCount == 6)
        #expect(volumes.activeCount == 1)
        #expect(volumes.totalBytes == 6_000 + 1_000 + 500 + 70 + 3)
        #expect(volumes.reclaimableBytes == 1_000 + 500 + 70)
        #expect(report.unusedVolumeGroups.map(\.composeProject) == ["shop", nil, nil])
        #expect(report.unusedVolumeGroups.map(\.isAnonymous) == [false, false, true])
        #expect(report.unusedVolumeGroups[0].volumes.map(\.name) == ["shop_pgdata"])
        #expect(report.unusedVolumeGroups[0].volumes[0].mayHoldData)
        // Unknown size (-1) is reported as nil rather than negative.
        #expect(report.unusedVolumeGroups[1].volumes.map(\.bytes) == [70, nil])
        #expect(report.unusedVolumeGroups[2].volumes.count == 1)

        let cache = try #require(report.summary(.buildCache))
        #expect(cache.totalCount == 3)
        #expect(cache.activeCount == 1)
        #expect(cache.totalBytes == 2_000 + 3_000)
        #expect(cache.reclaimableBytes == 3_000)
        #expect(report.buildCache.lastUsedAt == DockerDate.parse("2024-05-02T10:00:00Z"))

        // Round-trips through JSON for `--json` and the app.
        let encoded = try JSONEncoder().encode(report)
        #expect(try JSONDecoder().decode(DockerReport.self, from: encoded).unusedImages.count == 2)
    }

    @Test func prefersServerUsageTotals() throws {
        let df = try JSONDecoder().decode(SystemDFResponse.self, from: Data(Self.usageFixture.utf8))
        let report = DockerReport(systemDF: df, version: nil, socketPath: nil)
        let volumes = try #require(report.summary(.volumes))
        #expect(volumes.totalCount == 2)
        #expect(volumes.totalBytes == 5_000)
        #expect(volumes.reclaimableBytes == 4_000)
        #expect(volumes.activeCount == 1)
        // Empty usage objects fall back to local arithmetic.
        #expect(report.summary(.images)?.totalCount == 0)
        #expect(report.unusedVolumeGroups.first?.composeProject == "web")
    }

    @Test func parsesDockerDates() {
        #expect(DockerDate.parse("2024-05-02T10:00:00.123456789Z") == DockerDate.parse("2024-05-02T10:00:00Z"))
        #expect(DockerDate.parse("2026-06-27T20:16:03+07:00") == DockerDate.parse("2026-06-27T13:16:03Z"))
        #expect(DockerDate.parse("0001-01-01T00:00:00Z") == nil)
        #expect(DockerDate.parse(nil) == nil)
    }

    @Test func detectsAnonymousVolumes() {
        let hex = String(repeating: "ab12", count: 16)
        #expect(DockerReport.isAnonymousVolume(name: hex, labels: [:]))
        #expect(!DockerReport.isAnonymousVolume(name: "pgdata", labels: [:]))
        #expect(DockerReport.isAnonymousVolume(name: "x", labels: ["com.docker.volume.anonymous": ""]))
    }

    static let legacyFixture = """
    {
      "LayersSize": 900,
      "Images": [
        {"Id": "sha256:aaaaaaaaaaaaaaaa", "RepoTags": ["app:latest"], "Created": 1700000000, "Size": 300, "SharedSize": 100, "Containers": 1},
        {"Id": "sha256:bbbbbbbbbbbbbbbb", "RepoTags": ["old:1"], "Created": 1600000000, "Size": 500, "SharedSize": 100, "Containers": 0, "Labels": null},
        {"Id": "sha256:cccccccccccccccc", "RepoTags": ["<none>:<none>"], "Size": 200, "SharedSize": -1, "Containers": 0}
      ],
      "Containers": [
        {"Id": "c1", "Names": ["/web"], "Image": "app:latest", "State": "running", "Status": "Up 2 hours", "SizeRw": 10, "Created": 1700000100},
        {"Id": "c2", "Names": ["/shop-db-1"], "Image": "postgres:16", "State": "exited", "Status": "Exited (0) 3 days ago",
         "SizeRw": 50, "Labels": {"com.docker.compose.project": "shop"}}
      ],
      "Volumes": [
        {"Name": "shop_pgdata", "Driver": "local", "CreatedAt": "2024-01-01T00:00:00Z",
         "Labels": {"com.docker.compose.project": "shop"}, "UsageData": {"Size": 1000, "RefCount": 0}},
        {"Name": "\(String(repeating: "0f", count: 32))", "Driver": "local", "Labels": null, "UsageData": {"Size": 500, "RefCount": 0}},
        {"Name": "loose", "UsageData": {"Size": 70, "RefCount": 0}},
        {"Name": "remote", "Driver": "nfs", "UsageData": {"Size": -1, "RefCount": 0}},
        {"Name": "live", "UsageData": {"Size": 6000, "RefCount": 1}},
        {"Name": "tiny", "UsageData": {"Size": 3, "RefCount": -1}}
      ],
      "BuildCache": [
        {"ID": "b1", "Type": "regular", "InUse": true, "Shared": false, "Size": 2000, "LastUsedAt": "2024-05-01T10:00:00.5Z"},
        {"ID": "b2", "Type": "regular", "InUse": false, "Shared": false, "Size": 3000, "LastUsedAt": "2024-05-02T10:00:00Z"},
        {"ID": "b3", "Type": "source.local", "InUse": false, "Shared": true, "Size": 4000}
      ]
    }
    """

    static let usageFixture = """
    {
      "Images": [], "Containers": [], "BuildCache": [],
      "ImageUsage": {}, "ContainerUsage": {}, "BuildCacheUsage": {},
      "VolumeUsage": {
        "ActiveCount": 1, "TotalCount": 2, "TotalSize": 5000, "Reclaimable": 4000,
        "Items": [
          {"Name": "web_data", "Labels": {"com.docker.compose.project": "web"}, "UsageData": {"Size": 4000, "RefCount": 0}},
          {"Name": "db", "UsageData": {"Size": 1000, "RefCount": 1}}
        ]
      }
    }
    """
}
