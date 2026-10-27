import Foundation

// Engine API payloads. Every field is optional because it varies across API versions.

struct DockerVersionResponse: Decodable {
    var Version: String?
    var ApiVersion: String?
    var Os: String?
    var Arch: String?
    var Platform: Platform?

    struct Platform: Decodable {
        var Name: String?
    }
}

/// `GET /system/df`. API >= 1.52 adds `*Usage` objects carrying server-computed totals;
/// older daemons only return the flat arrays plus `LayersSize`.
struct SystemDFResponse: Decodable {
    var LayersSize: Int64?
    var Images: [Image]?
    var Containers: [Container]?
    var Volumes: [Volume]?
    var BuildCache: [BuildCacheRecord]?
    var ImageUsage: Usage<Image>?
    var ContainerUsage: Usage<Container>?
    var VolumeUsage: Usage<Volume>?
    var BuildCacheUsage: Usage<BuildCacheRecord>?

    struct Usage<Item: Decodable>: Decodable {
        var ActiveCount: Int?
        var TotalCount: Int?
        var TotalSize: Int64?
        var Reclaimable: Int64?
        var Items: [Item]?
    }

    struct Image: Decodable {
        var Id: String?
        var RepoTags: [String]?
        var RepoDigests: [String]?
        /// Unix seconds.
        var Created: Int64?
        var Size: Int64?
        /// -1 when not computed.
        var SharedSize: Int64?
        /// -1 when not computed.
        var Containers: Int?
        var Labels: [String: String]?
    }

    struct Container: Decodable {
        var Id: String?
        var Names: [String]?
        var Image: String?
        var ImageID: String?
        /// Unix seconds.
        var Created: Int64?
        var State: String?
        var Status: String?
        var SizeRw: Int64?
        var SizeRootFs: Int64?
        var Labels: [String: String]?
    }

    struct Volume: Decodable {
        var Name: String?
        var Driver: String?
        var Mountpoint: String?
        var CreatedAt: String?
        var Labels: [String: String]?
        var Scope: String?
        var UsageData: UsageData?

        struct UsageData: Decodable {
            /// -1 when the driver does not report sizes.
            var Size: Int64?
            /// -1 when not computed.
            var RefCount: Int?
        }
    }

    struct BuildCacheRecord: Decodable {
        var ID: String?
        var `Type`: String?
        var Description: String?
        var InUse: Bool?
        var Shared: Bool?
        var Size: Int64?
        var CreatedAt: String?
        var LastUsedAt: String?
        var UsageCount: Int?
    }

    /// Prefers the legacy arrays, falling back to `*Usage.Items` (verbose responses on new daemons).
    var images: [Image] { nonEmpty(Images) ?? ImageUsage?.Items ?? [] }
    var containers: [Container] { nonEmpty(Containers) ?? ContainerUsage?.Items ?? [] }
    var volumes: [Volume] { nonEmpty(Volumes) ?? VolumeUsage?.Items ?? [] }
    var buildCache: [BuildCacheRecord] { nonEmpty(BuildCache) ?? BuildCacheUsage?.Items ?? [] }

    private func nonEmpty<T>(_ items: [T]?) -> [T]? {
        items.flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct ContainerInspectResponse: Decodable {
    var State: State?

    struct State: Decodable {
        var FinishedAt: String?
    }
}

struct DockerErrorResponse: Decodable {
    var message: String?
}

enum DockerDate {
    /// Parses Docker's RFC 3339 timestamps (up to nanosecond precision). Zero dates map to nil.
    static func parse(_ text: String?) -> Date? {
        guard var text, !text.isEmpty else { return nil }
        // ISO8601DateFormatter only handles millisecond fractions; drop the fraction entirely.
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            text.removeSubrange(dot..<zone)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: text), date.timeIntervalSince1970 > 0 else { return nil }
        return date
    }

    static func fromUnix(_ seconds: Int64?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
