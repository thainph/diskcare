import Foundation

/// One Engine API call. `path` is unencoded; `target` adds percent-encoding and the query string.
public struct DockerRequest: Sendable, Equatable, CustomStringConvertible {
    public enum Method: String, Sendable { case get = "GET", post = "POST", delete = "DELETE" }

    public var method: Method
    public var path: String
    /// Kept in order so request targets are deterministic.
    public var query: [(name: String, value: String)]
    public var body: Data?
    public var timeout: TimeInterval

    public init(_ method: Method, _ path: String, query: [(String, String)] = [], body: Data? = nil, timeout: TimeInterval = 30) {
        self.method = method
        self.path = path
        self.query = query.map { (name: $0.0, value: $0.1) }
        self.body = body
        self.timeout = timeout
    }

    /// Path segments keep `/` and `:` (image references like `ghcr.io/org/app:1`); query values are strictly encoded.
    public var target: String {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: Self.pathAllowed) ?? path
        guard !query.isEmpty else { return encodedPath }
        return encodedPath + "?" + query.map { "\(Self.encodeQuery($0.name))=\(Self.encodeQuery($0.value))" }.joined(separator: "&")
    }

    public var description: String { "\(method.rawValue) \(target)" }

    public static func == (lhs: DockerRequest, rhs: DockerRequest) -> Bool {
        lhs.method == rhs.method && lhs.target == rhs.target && lhs.body == rhs.body
    }

    static func encodeQuery(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? text
    }

    private static let queryAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    private static let pathAllowed = queryAllowed.union(CharacterSet(charactersIn: "/:@"))

    /// Docker's `filters` query parameter: `{"key":["value",...]}` as compact JSON with sorted keys.
    static func filters(_ filters: [String: [String]]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(filters)) ?? Data("{}".utf8), as: UTF8.self)
    }
}

/// Sends Engine API requests. Abstracted so cleanup logic can be tested without a daemon.
public protocol DockerTransport: Sendable {
    func send(_ request: DockerRequest) throws -> HTTPResponse
}

public struct UnixSocketDockerTransport: DockerTransport {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func send(_ request: DockerRequest) throws -> HTTPResponse {
        try UnixSocketHTTPClient(socketPath: socketPath, timeout: request.timeout)
            .request(request.method.rawValue, request.target, body: request.body)
    }
}

extension DockerTransport {
    /// Sends and requires a 2xx status, mapping Docker's `{"message": ...}` errors.
    @discardableResult
    func call(_ request: DockerRequest) throws -> HTTPResponse {
        let response = try send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw DockerClientError.http(status: response.statusCode, message: Self.errorMessage(response))
        }
        return response
    }

    func call<T: Decodable>(_ request: DockerRequest, as type: T.Type) throws -> T {
        let body = try call(request).body
        do {
            return try JSONDecoder().decode(type, from: body)
        } catch {
            throw DockerClientError.decoding(endpoint: request.path, detail: "\(error)")
        }
    }

    /// Returns nil on 404 instead of throwing.
    func callIfExists<T: Decodable>(_ request: DockerRequest, as type: T.Type) throws -> T? {
        do {
            return try call(request, as: type)
        } catch DockerClientError.http(status: 404, _) {
            return nil
        }
    }

    static func errorMessage(_ response: HTTPResponse) -> String {
        (try? JSONDecoder().decode(DockerErrorResponse.self, from: response.body))?.message
            ?? String(decoding: response.body.prefix(200), as: UTF8.self)
    }
}

// MARK: - Payloads used by cleanup

struct ContainerStateResponse: Decodable {
    var Id: String?
    var State: State?

    struct State: Decodable {
        var Status: String?
        var Running: Bool?
        var Paused: Bool?
        var Restarting: Bool?
    }
}

struct ContainerSummaryResponse: Decodable {
    var Id: String?
    var Names: [String]?
    var State: String?
}

struct ImageInspectResponse: Decodable {
    var Id: String?
    var RepoTags: [String]?
}

struct VolumeInspectResponse: Decodable {
    var Name: String?
    var Driver: String?
    var Labels: [String: String]?
    var CreatedAt: String?
}

struct BuildPruneResponse: Decodable {
    var CachesDeleted: [String]?
    var SpaceReclaimed: Int64?
}

struct ContainerCreateResponse: Decodable {
    var Id: String
}

struct ContainerWaitResponse: Decodable {
    var StatusCode: Int
    var Error: WaitError?

    struct WaitError: Decodable {
        var Message: String?
    }
}
