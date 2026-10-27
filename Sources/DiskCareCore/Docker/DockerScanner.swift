import Foundation

/// Entry point: queries the local Docker daemon and summarises reclaimable space. Read-only.
public enum DockerScanner {
    public struct Options: Sendable {
        /// Overrides socket discovery.
        public var socketPath: String?
        /// Used for `_ping` and `/version`; a stopped daemon fails fast.
        public var probeTimeout: TimeInterval = 2
        public var diskUsageTimeout: TimeInterval = 60
        /// Look up `FinishedAt` for up to this many stopped containers (one request each).
        public var inspectContainerLimit = 50

        public init(socketPath: String? = nil) {
            self.socketPath = socketPath
        }
    }

    public static func scan(_ options: Options = Options()) -> DockerReport {
        let socketPath: String
        do {
            socketPath = try options.socketPath ?? DockerClient.resolveSocketPath()
        } catch {
            return .unavailable(socketPath: nil, error: "\(error)")
        }
        let client = DockerClient(socketPath: socketPath)
        do {
            try client.ping(timeout: options.probeTimeout)
        } catch {
            return .unavailable(socketPath: socketPath, error: "Docker daemon not reachable: \(error)")
        }
        let version = try? client.version(timeout: options.probeTimeout)
        let df: SystemDFResponse
        do {
            df = try client.systemDF(timeout: options.diskUsageTimeout)
        } catch {
            return .unavailable(socketPath: socketPath, error: "system df failed: \(error)")
        }

        var finishedAt: [String: Date] = [:]
        let stopped = df.containers
            .filter { !DockerReport.isActive(state: $0.State ?? "") }
            .compactMap(\.Id)
            .prefix(options.inspectContainerLimit)
        for id in stopped {
            if let date = try? client.containerFinishedAt(id: id, timeout: options.probeTimeout) { finishedAt[id] = date }
        }
        return DockerReport(systemDF: df, version: version, socketPath: socketPath, finishedAt: finishedAt)
    }

    public static func scan(_ options: Options = Options()) async -> DockerReport {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: scan(options))
            }
        }
    }
}
