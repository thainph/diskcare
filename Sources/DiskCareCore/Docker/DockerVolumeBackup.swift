import Foundation

public enum DockerBackupError: Error, Sendable, CustomStringConvertible {
    case volumeNotFound(String)
    case invalidName(String)
    case helperFailed(status: Int, output: String)
    case archiveMissing(String)
    case archiveCorrupt(path: String, detail: String)
    case pullFailed(String)

    public var description: String {
        switch self {
        case .volumeNotFound(let name): "volume \(name) not found"
        case .invalidName(let name): "invalid volume name: \(name)"
        case .helperFailed(let status, let output): "helper container exited with \(status)\(output.isEmpty ? "" : ": \(output)")"
        case .archiveMissing(let path): "archive not written: \(path.abbreviatingHome)"
        case .archiveCorrupt(let path, let detail): "archive \(path.abbreviatingHome) is not readable: \(detail)"
        case .pullFailed(let detail): "cannot pull helper image: \(detail)"
        }
    }
}

/// Metadata written next to each archive so a restore can recreate the volume with its labels.
public struct DockerVolumeBackupInfo: Sendable, Codable {
    public let volume: String
    public let driver: String?
    public let labels: [String: String]
    public let createdAt: String?
    public let archivedAt: Date
}

/// Exports and imports named volumes as `.tar.gz` files using a short-lived helper container.
///
/// The daemon (OrbStack, Docker Desktop) must be able to bind-mount `directory` from the host;
/// both share the home folder by default.
public struct DockerVolumeBackup: Sendable {
    public let transport: any DockerTransport
    public let directory: URL
    public var helperImage = "alpine:latest"
    /// Upper bound for one tar run (large volumes take a while).
    public var helperTimeout: TimeInterval = 3_600
    /// Checks a finished archive; defaults to a full `tar -tzf` read so truncated files are caught.
    public var verifyArchive: @Sendable (URL) throws -> Void = DockerVolumeBackup.listArchive

    public static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("DiskCareBackups/docker-volumes", isDirectory: true)
    }

    public init(transport: any DockerTransport, directory: URL = DockerVolumeBackup.defaultDirectory) {
        self.transport = transport
        self.directory = directory
    }

    static let helperLabel = "dev.diskcare.helper"

    // MARK: Backup

    /// Writes `<directory>/<volume>-<yyyyMMdd-HHmmss>.tar.gz` (+ `.json` metadata) and returns the archive URL.
    public func backup(volume name: String, now: Date = Date()) throws -> URL {
        try Self.validate(name)
        guard let volume = try transport.callIfExists(DockerRequest(.get, "/volumes/\(name)"), as: VolumeInspectResponse.self) else {
            throw DockerBackupError.volumeNotFound(name)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(name)-\(Self.timestamp(now)).tar.gz"
        let archive = directory.appendingPathComponent(fileName)
        let partial = directory.appendingPathComponent(".\(fileName).partial")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        try runHelper(
            purpose: "backup",
            command: ["tar", "czf", "/backup/\(partial.lastPathComponent)", "-C", "/volume", "."],
            mounts: [
                Self.volumeMount(name, target: "/volume", readOnly: true),
                Self.bindMount(directory.path, target: "/backup", readOnly: false),
            ]
        )
        guard FileManager.default.fileExists(atPath: partial.path) else { throw DockerBackupError.archiveMissing(partial.path) }
        try verifyArchive(partial)
        try FileManager.default.moveItem(at: partial, to: archive)

        let info = DockerVolumeBackupInfo(
            volume: name, driver: volume.Driver, labels: volume.Labels ?? [:], createdAt: volume.CreatedAt, archivedAt: now
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(info).write(to: Self.metadataURL(for: archive))
        return archive
    }

    // MARK: Restore

    /// Extracts `archive` into `volume` (created if missing, with the labels recorded at backup time).
    /// Refuses a non-empty existing volume unless `allowNonEmpty`.
    public func restore(archive: URL, into name: String, allowNonEmpty: Bool = false) throws {
        try Self.validate(name)
        let archive = archive.standardizedFileURL
        guard FileManager.default.fileExists(atPath: archive.path) else { throw DockerBackupError.archiveMissing(archive.path) }

        let existing = try transport.callIfExists(DockerRequest(.get, "/volumes/\(name)"), as: VolumeInspectResponse.self)
        if existing == nil {
            let info = Self.metadata(for: archive)
            var payload: [String: Any] = ["Name": name]
            // Labels (e.g. compose project) only make sense when restoring under the original name.
            if let info, info.volume == name {
                payload["Labels"] = info.labels
                if let driver = info.driver { payload["Driver"] = driver }
            }
            try transport.call(DockerRequest(.post, "/volumes/create", body: try JSONSerialization.data(withJSONObject: payload)))
        }

        let script = """
        if [ "$ALLOW_NONEMPTY" != 1 ] && [ -n "$(ls -A /volume)" ]; then echo "volume is not empty" >&2; exit 3; fi
        tar xzf "/backup/$ARCHIVE" -C /volume
        """
        try runHelper(
            purpose: "restore",
            command: ["sh", "-c", script],
            environment: ["ARCHIVE=\(archive.lastPathComponent)", "ALLOW_NONEMPTY=\(allowNonEmpty ? 1 : 0)"],
            mounts: [
                Self.volumeMount(name, target: "/volume", readOnly: false),
                Self.bindMount(archive.deletingLastPathComponent().path, target: "/backup", readOnly: true),
            ]
        )
    }

    public static func metadataURL(for archive: URL) -> URL {
        let name = archive.lastPathComponent
        let base = name.hasSuffix(".tar.gz") ? String(name.dropLast(".tar.gz".count)) : name
        return archive.deletingLastPathComponent().appendingPathComponent(base + ".json")
    }

    public static func metadata(for archive: URL) -> DockerVolumeBackupInfo? {
        guard let data = try? Data(contentsOf: metadataURL(for: archive)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DockerVolumeBackupInfo.self, from: data)
    }

    // MARK: Helper container

    /// Create → start → wait → remove. The container is always removed, even on failure.
    func runHelper(purpose: String, command: [String], environment: [String] = [], mounts: [[String: Any]]) throws {
        try ensureHelperImage()
        let config: [String: Any] = [
            "Image": helperImage,
            "Cmd": command,
            "Env": environment,
            "Labels": [Self.helperLabel: purpose],
            "NetworkDisabled": true,
            "HostConfig": ["Mounts": mounts, "NetworkMode": "none"],
        ]
        let name = "diskcare-\(purpose)-\(UUID().uuidString.prefix(8).lowercased())"
        let created = try transport.call(
            DockerRequest(.post, "/containers/create", query: [("name", name)], body: try JSONSerialization.data(withJSONObject: config)),
            as: ContainerCreateResponse.self
        )
        defer { _ = try? transport.send(DockerRequest(.delete, "/containers/\(created.Id)", query: [("force", "true")])) }

        try transport.call(DockerRequest(.post, "/containers/\(created.Id)/start"))
        let result = try transport.call(
            DockerRequest(.post, "/containers/\(created.Id)/wait", timeout: helperTimeout),
            as: ContainerWaitResponse.self
        )
        guard result.StatusCode == 0 else {
            var output = logs(of: created.Id)
            if let message = result.Error?.Message, !message.isEmpty { output = output.isEmpty ? message : "\(message); \(output)" }
            throw DockerBackupError.helperFailed(status: result.StatusCode, output: output)
        }
    }

    /// Pulls the helper image once; later runs reuse the local copy.
    func ensureHelperImage() throws {
        if try transport.callIfExists(DockerRequest(.get, "/images/\(helperImage)/json"), as: ImageInspectResponse.self) != nil { return }
        let (image, tag) = Self.splitReference(helperImage)
        // The pull streams JSON progress lines and reports failures inline with HTTP 200.
        let response = try transport.call(DockerRequest(.post, "/images/create", query: [("fromImage", image), ("tag", tag)], timeout: 600))
        for line in String(decoding: response.body, as: UTF8.self).split(separator: "\n") {
            if let message = (try? JSONDecoder().decode(PullProgress.self, from: Data(line.utf8)))?.error {
                throw DockerBackupError.pullFailed(message)
            }
        }
    }

    private struct PullProgress: Decodable {
        var error: String?
    }

    private func logs(of id: String) -> String {
        let request = DockerRequest(.get, "/containers/\(id)/logs", query: [("stdout", "1"), ("stderr", "1"), ("tail", "20")])
        guard let response = try? transport.call(request) else { return "" }
        return Self.demultiplex(response.body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips the 8-byte stream headers Docker adds to non-TTY container logs.
    static func demultiplex(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        var index = 0
        while index + 8 <= bytes.count, bytes[index] <= 2, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 0 {
            let size = bytes[(index + 4)..<(index + 8)].reduce(0) { $0 << 8 | Int($1) }
            let end = min(bytes.count, index + 8 + size)
            output += bytes[(index + 8)..<end]
            index = end
        }
        // Not multiplexed (TTY or unknown format): return as-is.
        if index == 0 { return String(decoding: bytes, as: UTF8.self) }
        return String(decoding: output, as: UTF8.self)
    }

    static func splitReference(_ reference: String) -> (String, String) {
        // A colon after the last slash separates the tag (a colon before it belongs to a registry port).
        if let colon = reference.lastIndex(of: ":"), !reference[colon...].contains("/") {
            return (String(reference[..<colon]), String(reference[reference.index(after: colon)...]))
        }
        return (reference, "latest")
    }

    static func volumeMount(_ name: String, target: String, readOnly: Bool) -> [String: Any] {
        // Volume mounts would silently create a missing volume; callers inspect it first.
        ["Type": "volume", "Source": name, "Target": target, "ReadOnly": readOnly]
    }

    static func bindMount(_ path: String, target: String, readOnly: Bool) -> [String: Any] {
        ["Type": "bind", "Source": path, "Target": target, "ReadOnly": readOnly]
    }

    /// Docker's own volume name rule; also keeps archive names and paths safe.
    static func validate(_ name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), first.isASCII,
              name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DockerBackupError.invalidName(name)
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// Reads the whole archive with the system `tar`, so a truncated or corrupt gzip stream fails here.
    @Sendable public static func listArchive(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tzf", url.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let message = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DockerBackupError.archiveCorrupt(
                path: url.path, detail: String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
