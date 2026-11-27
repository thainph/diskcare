import Darwin
import Foundation

/// One line of the deletion audit log.
public struct DeletionRecord: Sendable, Codable, Equatable {
    public let time: Date
    public let path: String
    public let bytes: Int64
    /// `delete`, `trash`, or the native command that was run.
    public let mode: String
    /// What asked for it: `artifact`, `worktree`, `cache-item`, `cache-entry`.
    public let source: String
    /// `ok`, or the error.
    public let result: String

    public init(time: Date = Date(), path: String, bytes: Int64, mode: String, source: String, result: String) {
        self.time = time
        self.path = path
        self.bytes = bytes
        self.mode = mode
        self.source = source
        self.result = result
    }
}

/// Append-only JSONL audit log of everything DiskCare deleted or tried to delete.
public struct DeletionLog: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public static var defaultPath: String {
        (HistoryStore.defaultPath as NSString).deletingLastPathComponent + "/deletions.jsonl"
    }

    public static var standard: DeletionLog { DeletionLog(path: defaultPath) }

    /// Best effort: a failing log never blocks a cleanup. Each record is one `write(2)` to an
    /// `O_APPEND` descriptor, so concurrent cleaners do not interleave lines.
    public func append(_ record: DeletionRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }

    public func records() -> [DeletionRecord] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(DeletionRecord.self, from: Data($0.utf8)) }
    }
}
