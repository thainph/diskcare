import Darwin
import Foundation

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let reason: String
    /// Header names are lowercased.
    public let headers: [String: String]
    public let body: Data
}

public enum HTTPClientError: Error, Sendable, CustomStringConvertible {
    case socketPathTooLong(String)
    case socketFailed(Int32)
    case connectFailed(path: String, errno: Int32)
    case sendFailed(Int32)
    case receiveFailed(Int32)
    case timedOut
    case malformedResponse(String)
    case bodyTooLarge(Int)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path): "socket path too long: \(path)"
        case .socketFailed(let code): "socket() failed: \(String(cString: strerror(code)))"
        case .connectFailed(let path, let code): "cannot connect to \(path): \(String(cString: strerror(code)))"
        case .sendFailed(let code): "send failed: \(String(cString: strerror(code)))"
        case .receiveFailed(let code): "receive failed: \(String(cString: strerror(code)))"
        case .timedOut: "timed out"
        case .malformedResponse(let detail): "malformed HTTP response: \(detail)"
        case .bodyTooLarge(let limit): "response larger than \(limit) bytes"
        }
    }
}

/// Minimal HTTP/1.1 GET client over a unix domain socket (one request per connection).
public struct UnixSocketHTTPClient: Sendable {
    public let socketPath: String
    /// Applies to connect and to the whole request/response exchange.
    public let timeout: TimeInterval
    public let maxResponseBytes: Int

    public init(socketPath: String, timeout: TimeInterval = 2, maxResponseBytes: Int = 256 << 20) {
        self.socketPath = socketPath
        self.timeout = timeout
        self.maxResponseBytes = maxResponseBytes
    }

    public func get(_ path: String, host: String = "localhost") throws -> HTTPResponse {
        let deadline = Date().addingTimeInterval(timeout)
        let fd = try connect(deadline: deadline)
        defer { close(fd) }

        let request = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: diskcare\r\nAccept: application/json\r\nConnection: close\r\n\r\n"
        try send(Array(request.utf8), on: fd, deadline: deadline)

        var buffer: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var head: HTTPResponseParser.Head?
        while true {
            if head == nil { head = try HTTPResponseParser.parseHead(buffer) }
            // Normally the server closes after the body; stop early if it keeps the connection open anyway.
            if let head, head.mayBeComplete(buffer), let response = try HTTPResponseParser.parse(buffer, isComplete: false) {
                return response
            }
            guard Date() < deadline else { throw HTTPClientError.timedOut }
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw HTTPClientError.timedOut }
                throw HTTPClientError.receiveFailed(errno)
            }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.count > maxResponseBytes { throw HTTPClientError.bodyTooLarge(maxResponseBytes) }
        }
        guard let response = try HTTPResponseParser.parse(buffer, isComplete: true) else {
            throw HTTPClientError.malformedResponse("connection closed early")
        }
        return response
    }

    /// Runs the blocking request on a detached thread so it never stalls the cooperative pool.
    public func get(_ path: String, host: String = "localhost") async throws -> HTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try get(path, host: host) })
            }
        }
    }

    private func connect(deadline: Date) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw HTTPClientError.socketPathTooLong(socketPath) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HTTPClientError.socketFailed(errno) }
        do {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var interval = timeval(seconds: max(0.01, deadline.timeIntervalSinceNow))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))

            // Non-blocking connect so a wedged daemon (full backlog) cannot hang us past the deadline.
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN else {
                    throw HTTPClientError.connectFailed(path: socketPath, errno: errno)
                }
                var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let milliseconds = Int32(max(0, deadline.timeIntervalSinceNow) * 1000)
                guard poll(&pollFD, 1, milliseconds) > 0 else { throw HTTPClientError.timedOut }
                var error: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
                if error != 0 { throw HTTPClientError.connectFailed(path: socketPath, errno: error) }
            }
            _ = fcntl(fd, F_SETFL, flags)
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private func send(_ bytes: [UInt8], on fd: Int32, deadline: Date) throws {
        var offset = 0
        while offset < bytes.count {
            guard Date() < deadline else { throw HTTPClientError.timedOut }
            let sent = bytes[offset...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { throw HTTPClientError.timedOut }
                throw HTTPClientError.sendFailed(errno)
            }
            offset += sent
        }
    }
}

private extension timeval {
    init(seconds: TimeInterval) {
        let whole = Int(seconds)
        self.init(tv_sec: whole, tv_usec: Int32((seconds - Double(whole)) * 1_000_000))
    }
}

/// Parses raw HTTP/1.1 response bytes; supports `Content-Length`, chunked encoding and read-until-close.
enum HTTPResponseParser {
    private static let crlf: [UInt8] = [13, 10]
    private static let headerEnd: [UInt8] = [13, 10, 13, 10]

    struct Head {
        let statusCode: Int
        let reason: String
        let headers: [String: String]
        let bodyStart: Int

        var hasNoBody: Bool { (100..<200).contains(statusCode) || statusCode == 204 || statusCode == 304 }
        var isChunked: Bool { headers["transfer-encoding"]?.lowercased().contains("chunked") == true }

        /// Cheap check used while streaming; `parse` does the real validation.
        func mayBeComplete(_ bytes: [UInt8]) -> Bool {
            if hasNoBody { return true }
            if isChunked { return bytes.count >= bodyStart + 5 && bytes.suffix(5).elementsEqual([48, 13, 10, 13, 10]) }
            if let length = headers["content-length"].flatMap({ Int($0) }) { return bytes.count >= bodyStart + length }
            return false
        }
    }

    /// Returns nil until the blank line terminating the headers has arrived.
    static func parseHead(_ bytes: [UInt8]) throws -> Head? {
        guard let headEnd = find(headerEnd, in: bytes, from: 0) else { return nil }
        let text = String(decoding: bytes[..<headEnd], as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            throw HTTPClientError.malformedResponse("bad status line: \(statusLine)")
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return Head(
            statusCode: status,
            reason: parts.count > 2 ? String(parts[2]) : "",
            headers: headers,
            bodyStart: headEnd + headerEnd.count
        )
    }

    /// Returns nil when more bytes are needed. With `isComplete` (peer closed) a truncated message throws instead.
    static func parse(_ bytes: [UInt8], isComplete: Bool) throws -> HTTPResponse? {
        guard let head = try parseHead(bytes) else {
            if isComplete { throw HTTPClientError.malformedResponse(bytes.isEmpty ? "empty response" : "incomplete headers") }
            return nil
        }
        let headers = head.headers
        let bodyStart = head.bodyStart
        let body: [UInt8]
        if head.hasNoBody {
            body = []
        } else if head.isChunked {
            guard let decoded = try decodeChunked(bytes, from: bodyStart) else {
                if isComplete { throw HTTPClientError.malformedResponse("truncated chunked body") }
                return nil
            }
            body = decoded
        } else if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else {
                throw HTTPClientError.malformedResponse("bad Content-Length: \(lengthText)")
            }
            guard bytes.count - bodyStart >= length else {
                if isComplete { throw HTTPClientError.malformedResponse("truncated body") }
                return nil
            }
            body = Array(bytes[bodyStart..<(bodyStart + length)])
        } else {
            // No framing: the body runs until the server closes the connection.
            guard isComplete else { return nil }
            body = Array(bytes[bodyStart...])
        }
        return HTTPResponse(statusCode: head.statusCode, reason: head.reason, headers: headers, body: Data(body))
    }

    /// Returns nil if the terminating zero-size chunk has not arrived yet.
    static func decodeChunked(_ bytes: [UInt8], from start: Int) throws -> [UInt8]? {
        var output: [UInt8] = []
        var position = start
        while true {
            guard let lineEnd = find(crlf, in: bytes, from: position) else { return nil }
            let line = String(decoding: bytes[position..<lineEnd], as: UTF8.self)
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeText, radix: 16), size >= 0 else {
                throw HTTPClientError.malformedResponse("bad chunk size: \(line)")
            }
            let dataStart = lineEnd + crlf.count
            // Trailers after the last chunk are ignored.
            if size == 0 { return output }
            guard bytes.count >= dataStart + size + crlf.count else { return nil }
            output.append(contentsOf: bytes[dataStart..<(dataStart + size)])
            guard bytes[dataStart + size] == 13, bytes[dataStart + size + 1] == 10 else {
                throw HTTPClientError.malformedResponse("missing CRLF after chunk")
            }
            position = dataStart + size + crlf.count
        }
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= pattern.count, start <= bytes.count - pattern.count else { return nil }
        var index = start
        while index <= bytes.count - pattern.count {
            if bytes[index] == pattern[0], bytes[index..<(index + pattern.count)].elementsEqual(pattern) { return index }
            index += 1
        }
        return nil
    }
}
