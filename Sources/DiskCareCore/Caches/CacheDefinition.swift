import Foundation

public enum CacheCategory: String, Sendable, Codable, CaseIterable {
    case packageManager, browserAutomation, build, ide, system, aiModels

    public var title: String {
        switch self {
        case .packageManager: "Package managers"
        case .browserAutomation: "Browser automation"
        case .build: "Build & dev tools"
        case .ide: "Editors & IDEs"
        case .system: "System & apps"
        case .aiModels: "AI models"
        }
    }
}

public enum CacheSafety: String, Sendable, Codable, CaseIterable {
    /// Pure cache: recreated automatically, nothing to re-download by hand.
    case safe
    /// Can be restored, but needs a re-download or rebuild (browsers, simulators, device symbols).
    case regenerable
    /// Looks like a cache but holds data the user cares about (models, archives). Report only.
    case userData

    public var isCleanable: Bool { self != .userData }
}

/// A cleanup command shipped by the tool that owns the cache (`brew cleanup -s`, `pnpm store prune`…).
public struct NativeCleanCommand: Sendable, Codable, Equatable {
    /// Executable names tried in order (e.g. `pip3`, `pip`), resolved through `CommandResolver`.
    public var executables: [String]
    public var arguments: [String]
    public var timeoutSeconds: Double

    public init(_ executables: [String], _ arguments: [String], timeoutSeconds: Double = 120) {
        self.executables = executables
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    public var display: String { ([executables.first ?? "?"] + arguments).joined(separator: " ") }
}

/// What to do when there is no usable native command.
public enum CacheFallback: String, Sendable, Codable {
    /// Delete everything inside each cache directory, keeping the directory itself.
    case deleteContents
    /// Only the native command may clean this cache (e.g. simulator devices).
    case none
}

/// How a cache directory is broken down into separately cleanable items.
public enum CacheItemRule: Sendable, Codable, Equatable {
    public enum Grouping: String, Sendable, Codable {
        /// `chromium-1228` and `chromium-1243` are versions of `chromium` (Playwright layout).
        case namePrefix
        /// All siblings in one directory are versions of the same thing.
        case parent
    }

    /// Children at `depth` are versions; the newest `keep` per group stay, older ones are recommended.
    case versions(depth: Int, keep: Int, grouping: Grouping)
    /// One item per child directory (Xcode DerivedData); unused for `staleDays` is recommended.
    case projects(staleDays: Int)
}

public struct CacheDefinition: Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var category: CacheCategory
    public var safety: CacheSafety
    /// Path patterns: a leading `~` is the home directory; `*`, `?` and `[…]` glob within a component.
    public var paths: [String]
    public var nativeCommand: NativeCleanCommand?
    public var fallback: CacheFallback
    public var itemRule: CacheItemRule?
    /// Shown next to the entry (what is lost, how it comes back).
    public var note: String?

    public init(
        id: String, title: String, category: CacheCategory, safety: CacheSafety, paths: [String],
        nativeCommand: NativeCleanCommand? = nil, fallback: CacheFallback = .deleteContents,
        itemRule: CacheItemRule? = nil, note: String? = nil
    ) {
        self.id = id
        self.title = title
        self.category = category
        self.safety = safety
        self.paths = paths
        self.nativeCommand = nativeCommand
        self.fallback = fallback
        self.itemRule = itemRule
        self.note = note
    }

    /// Existing directories matching the path patterns.
    public func resolvedPaths(home: String = NSHomeDirectory()) -> [String] {
        var seen = Set<String>()
        return paths.flatMap { CachePaths.expand($0, home: home) }.filter { seen.insert($0).inserted }
    }
}

public enum CachePaths {
    /// Expands `~` and glob components. Only existing real directories (not symlinks) are returned,
    /// sorted for stable output.
    public static func expand(_ pattern: String, home: String = NSHomeDirectory()) -> [String] {
        var path = pattern
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = home + path.dropFirst()
        }
        guard path.hasPrefix("/") else { return [] }

        var candidates = ["/"]
        for component in path.split(separator: "/").map(String.init) {
            var next: [String] = []
            for base in candidates {
                let prefix = base == "/" ? "/" : base + "/"
                if isGlob(component) {
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                    for name in names.sorted() where fnmatch(component, name, FNM_PERIOD) == 0 {
                        next.append(prefix + name)
                    }
                } else {
                    next.append(prefix + component)
                }
            }
            candidates = next
        }
        return candidates.map(ScanOptions.normalize).filter(isRealDirectory)
    }

    static func isGlob(_ component: String) -> Bool {
        component.contains { $0 == "*" || $0 == "?" || $0 == "[" }
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }
}
