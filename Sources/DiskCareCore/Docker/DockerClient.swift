import Foundation

public enum DockerClientError: Error, Sendable, CustomStringConvertible {
    case noSocket(checked: [String])
    case unsupportedHost(String)
    case http(status: Int, message: String)
    case decoding(endpoint: String, detail: String)

    public var description: String {
        switch self {
        case .noSocket(let checked): "no Docker socket found (checked \(checked.map(\.abbreviatingHome).joined(separator: ", ")))"
        case .unsupportedHost(let host): "unsupported DOCKER_HOST \(host) (only unix:// is supported)"
        case .http(let status, let message): "Docker API returned \(status): \(message)"
        case .decoding(let endpoint, let detail): "cannot decode \(endpoint): \(detail)"
        }
    }
}

/// Read-only Docker Engine API client over the local unix socket.
public struct DockerClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Honours `DOCKER_HOST=unix://…`, then OrbStack, Docker Desktop and the system default socket.
    public static func resolveSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        socketExists: (String) -> Bool = DockerClient.isSocket
    ) throws -> String {
        if let host = environment["DOCKER_HOST"], !host.isEmpty {
            guard host.hasPrefix("unix://") else { throw DockerClientError.unsupportedHost(host) }
            return String(host.dropFirst("unix://".count))
        }
        let candidates = [
            home + "/.orbstack/run/docker.sock",
            home + "/.docker/run/docker.sock",
            "/var/run/docker.sock",
        ]
        guard let path = candidates.first(where: socketExists) else { throw DockerClientError.noSocket(checked: candidates) }
        return path
    }

    /// `stat` follows symlinks, so `/var/run/docker.sock -> ~/.orbstack/...` counts.
    public static func isSocket(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFSOCK
    }

    public func ping(timeout: TimeInterval = 2) throws {
        _ = try request("/_ping", timeout: timeout)
    }

    func version(timeout: TimeInterval = 2) throws -> DockerVersionResponse {
        try decode(DockerVersionResponse.self, from: "/version", timeout: timeout)
    }

    /// Computing volume and layer sizes can take a while on large installs, hence the longer timeout.
    func systemDF(timeout: TimeInterval = 60) throws -> SystemDFResponse {
        try decode(SystemDFResponse.self, from: "/system/df", timeout: timeout)
    }

    func containerFinishedAt(id: String, timeout: TimeInterval = 2) throws -> Date? {
        let path = "/containers/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/json"
        return DockerDate.parse(try decode(ContainerInspectResponse.self, from: path, timeout: timeout).State?.FinishedAt)
    }

    private func request(_ path: String, timeout: TimeInterval) throws -> Data {
        let response = try UnixSocketHTTPClient(socketPath: socketPath, timeout: timeout).get(path)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(DockerErrorResponse.self, from: response.body))?.message
                ?? String(decoding: response.body.prefix(200), as: UTF8.self)
            throw DockerClientError.http(status: response.statusCode, message: message)
        }
        return response.body
    }

    private func decode<T: Decodable>(_ type: T.Type, from path: String, timeout: TimeInterval) throws -> T {
        let body = try request(path, timeout: timeout)
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw DockerClientError.decoding(endpoint: path, detail: "\(error)")
        }
    }
}
