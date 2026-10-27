import Darwin
import Foundation

/// Measures every catalogued cache with one parallel FileSystemScanner pass.
public enum CacheScanner {
    public struct Options: Sendable {
        public var definitions: [CacheDefinition]
        public var home: String
        public var resolver: CommandResolver
        public var now: Date
        public var workerCount: Int?
        public var priority: ScanPriority

        public init(
            definitions: [CacheDefinition] = CacheCatalog.definitions(),
            home: String = NSHomeDirectory(),
            resolver: CommandResolver = .standard(),
            now: Date = Date(),
            workerCount: Int? = nil,
            priority: ScanPriority = .userInitiated
        ) {
            self.priority = priority
            self.definitions = definitions
            self.home = home
            self.resolver = resolver
            self.now = now
            self.workerCount = workerCount
        }
    }

    public static func scan(_ options: Options = Options()) -> CacheReport {
        let clock = ContinuousClock.now
        // A directory belongs to the first definition that claims it.
        var claimed = Set<String>()
        let resolved = options.definitions.map { definition in
            (definition, definition.resolvedPaths(home: options.home).filter { claimed.insert($0).inserted })
        }

        // Every cache root is excluded from the others, so nested locations
        // (~/Library/Caches vs ~/Library/Caches/Homebrew) are counted once.
        var scanOptions = ScanOptions(roots: Array(claimed), excludedPaths: claimed, stayOnDevice: true, priority: options.priority)
        if let workers = options.workerCount { scanOptions.workerCount = workers }
        let tree = claimed.isEmpty ? nil : FileSystemScanner.scan(scanOptions)
        let index = TreeIndex(tree: tree, itemRoots: resolved.filter { $0.0.itemRule != nil }.flatMap(\.1))

        let entries = resolved.compactMap { definition, paths -> CacheEntry? in
            let roots = paths.compactMap { index.root(at: $0) }
            guard !roots.isEmpty else { return nil }
            var totals = Totals()
            for root in roots { totals.add(root.total) }
            return CacheEntry(
                id: definition.id, title: definition.title, category: definition.category, safety: definition.safety,
                paths: roots.map(\.path), bytes: totals.bytes, hardlinkedBytes: totals.hardlinkedBytes, files: totals.files,
                lastModifiedAt: date(totals.latestModification),
                method: method(for: definition, resolver: options.resolver),
                command: definition.nativeCommand.flatMap { options.resolver.resolve($0) != nil ? $0.display : nil },
                nativeCommand: definition.nativeCommand, fallback: definition.fallback,
                note: definition.note,
                items: items(for: definition, roots: roots, index: index, now: options.now)
            )
        }
        return CacheReport(
            scannedAt: options.now, durationSeconds: (ContinuousClock.now - clock).seconds,
            entries: entries.sorted { $0.bytes > $1.bytes }
        )
    }

    public static func scan(_ options: Options = Options()) async -> CacheReport {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                options.priority.applyToCurrentThread()
                continuation.resume(returning: scan(options))
            }
        }
    }

    static func method(for definition: CacheDefinition, resolver: CommandResolver) -> CacheCleanMethod {
        guard definition.safety.isCleanable else { return .reportOnly }
        if let command = definition.nativeCommand, resolver.resolve(command) != nil { return .native }
        return definition.fallback == .deleteContents ? .deleteContents : .reportOnly
    }

    // MARK: Items

    static func items(for definition: CacheDefinition, roots: [DirectoryNode], index: TreeIndex, now: Date) -> [CacheItem] {
        guard let rule = definition.itemRule else { return [] }
        let multipleRoots = roots.count > 1
        var candidates: [ItemCandidate] = []
        let depth: Int
        switch rule {
        case .versions(let ruleDepth, _, _): depth = ruleDepth
        case .projects: depth = 1
        }
        for root in roots {
            for node in index.descendants(of: root, depth: depth) {
                let relative = String(node.path.dropFirst(root.path.count + 1))
                guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
                let rootName = (root.path as NSString).lastPathComponent
                candidates.append(ItemCandidate(
                    id: definition.id + "/" + (multipleRoots ? rootName + "/" : "") + relative,
                    name: multipleRoots ? rootName + "/" + relative : relative,
                    node: node,
                    lastUsedAt: lastUsed(of: node, rule: rule)
                ))
            }
        }

        let marks: [String: Mark]
        switch rule {
        case .versions(_, let keep, let grouping):
            marks = olderVersions(candidates, keep: keep, grouping: grouping, now: now)
        case .projects(let staleDays):
            marks = staleProjects(candidates, staleDays: staleDays, now: now)
        }
        return candidates.map { candidate in
            let mark = marks[candidate.id]
            return CacheItem(
                id: candidate.id, entryID: definition.id, name: candidate.name, path: candidate.node.path,
                bytes: candidate.node.total.bytes, hardlinkedBytes: candidate.node.total.hardlinkedBytes,
                lastUsedAt: candidate.lastUsedAt, isRecommended: mark?.recommended ?? false, reason: mark?.reason
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    struct ItemCandidate {
        let id: String
        let name: String
        let node: DirectoryNode
        let lastUsedAt: Date?

        var directoryName: String { (node.path as NSString).lastPathComponent }
        var parentPath: String { (node.path as NSString).deletingLastPathComponent }
    }

    struct Mark {
        let reason: String
        let recommended: Bool
    }

    /// An old version touched this recently is probably still used by a pinned project.
    static let recentUseDays = 30

    /// Marks every candidate that is not among the newest `keep` of its group; it is recommended
    /// unless it was used within `recentUseDays`.
    static func olderVersions(_ candidates: [ItemCandidate], keep: Int, grouping: CacheItemRule.Grouping, now: Date) -> [String: Mark] {
        var groups: [String: [ItemCandidate]] = [:]
        for candidate in candidates {
            switch grouping {
            case .parent:
                groups[candidate.parentPath, default: []].append(candidate)
            case .namePrefix:
                // `chromium_headless_shell-1228` → group `chromium_headless_shell`; other names stay alone.
                guard let product = revisionedProduct(candidate.directoryName) else { continue }
                groups[candidate.parentPath + "/" + product, default: []].append(candidate)
            }
        }
        var marks: [String: Mark] = [:]
        for members in groups.values {
            let ordered = members.sorted {
                let (left, right) = (VersionNumber($0.directoryName), VersionNumber($1.directoryName))
                if left != right { return left > right }
                return ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast)
            }
            guard let newest = ordered.first else { continue }
            for old in ordered.dropFirst(max(0, keep)) {
                let days = old.lastUsedAt.map { Int(now.timeIntervalSince($0) / 86_400) }
                if let days, days < recentUseDays {
                    marks[old.id] = Mark(reason: "older than \(newest.directoryName), but used \(days)d ago", recommended: false)
                } else {
                    marks[old.id] = Mark(reason: "older than \(newest.directoryName)", recommended: true)
                }
            }
        }
        return marks
    }

    /// `chromium-1228` → `chromium`; nil when the name does not end in `-<digits>`.
    static func revisionedProduct(_ name: String) -> String? {
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let revision = name[name.index(after: dash)...]
        guard !revision.isEmpty, revision.allSatisfy({ $0.isASCII && $0.isNumber }), dash > name.startIndex else { return nil }
        return String(name[..<dash])
    }

    static func staleProjects(_ candidates: [ItemCandidate], staleDays: Int, now: Date) -> [String: Mark] {
        var marks: [String: Mark] = [:]
        for candidate in candidates where !candidate.directoryName.hasSuffix(".noindex") {
            guard let used = candidate.lastUsedAt else { continue }
            let days = Int(now.timeIntervalSince(used) / 86_400)
            if days >= staleDays { marks[candidate.id] = Mark(reason: "unused \(days)d", recommended: true) }
        }
        return marks
    }

    static func lastUsed(of node: DirectoryNode, rule: CacheItemRule) -> Date? {
        if case .projects = rule,
           let plist = NSDictionary(contentsOfFile: node.path + "/info.plist"),
           let accessed = plist["LastAccessedDate"] as? Date {
            return accessed
        }
        var info = stat()
        let directoryModified = stat(node.path, &info) == 0 ? Int64(info.st_mtimespec.tv_sec) : 0
        return date(max(node.total.latestModification, directoryModified))
    }

    static func date(_ seconds: Int64) -> Date? {
        seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(seconds)) : nil
    }
}

/// Lookups into a scan tree: roots by path and the shallow descendants of item roots.
struct TreeIndex {
    private let nodes: [DirectoryNode]
    private let roots: [String: Int]
    private let children: [Int32: [Int]]

    init(tree: ScanTree?, itemRoots: [String], maxDepth: Int = 2) {
        nodes = tree?.nodes ?? []
        var roots: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() where node.parent < 0 {
            roots[node.path] = offset
        }
        self.roots = roots

        // Children always have larger ids than their parent, so one forward pass finds shallow descendants.
        var depth: [Int32: Int] = [:]
        for path in itemRoots {
            if let offset = roots[path] { depth[nodes[offset].id] = 0 }
        }
        var children: [Int32: [Int]] = [:]
        for (offset, node) in nodes.enumerated() where node.parent >= 0 {
            guard let parentDepth = depth[node.parent], parentDepth < maxDepth else { continue }
            depth[node.id] = parentDepth + 1
            children[node.parent, default: []].append(offset)
        }
        self.children = children
    }

    func root(at path: String) -> DirectoryNode? {
        roots[path].map { nodes[$0] }
    }

    func descendants(of node: DirectoryNode, depth: Int) -> [DirectoryNode] {
        var level = [node]
        for _ in 0..<depth {
            level = level.flatMap { children[$0.id, default: []].map { nodes[$0] } }
        }
        return level
    }
}
