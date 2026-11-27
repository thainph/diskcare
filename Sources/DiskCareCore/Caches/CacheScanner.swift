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
        public var progress: ScanProgress?
        /// What points into build output; nil = take a snapshot when a Cargo build dir is measured.
        public var inUse: InUseIndex?
        /// `.terraform` dirs from a project scan; nil = unknown, so no provider version is recommended.
        public var terraformDirs: [String]?
        /// Project roots (for `.vscode/settings.json` references and protection of the roots).
        public var scanRoots: [String] = []

        public init(
            definitions: [CacheDefinition] = CacheCatalog.definitions(),
            home: String = NSHomeDirectory(),
            resolver: CommandResolver = .standard(),
            now: Date = Date(),
            workerCount: Int? = nil,
            priority: ScanPriority = .userInitiated,
            progress: ScanProgress? = nil
        ) {
            self.priority = priority
            self.progress = progress
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
        let unreadable = Set(options.definitions.flatMap { $0.excludedPaths(home: options.home) })
        var scanOptions = ScanOptions(roots: Array(claimed), excludedPaths: claimed.union(unreadable), stayOnDevice: true, priority: options.priority, progress: options.progress)
        if let workers = options.workerCount { scanOptions.workerCount = workers }
        let tree = claimed.isEmpty ? nil : FileSystemScanner.scan(scanOptions)
        var depths: [String: Int] = [:]
        for (definition, paths) in resolved {
            for path in paths { depths[path] = definition.itemRule?.indexDepth ?? TreeIndex.defaultDepth }
        }
        let index = TreeIndex(tree: tree, itemRoots: depths)
        let hasCargo = resolved.contains { definition, paths in
            if case .cargoProfiles = definition.itemRule { return !paths.isEmpty }
            return false
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CARGO_HOME"] = CargoBuildLocator.cargoHome(home: options.home, environment: environment)
        let inUse = options.inUse ?? (hasCargo
            ? InUseIndex.snapshot(home: options.home, cargoHome: environment["CARGO_HOME"], scanRoots: options.scanRoots) : .empty)
        let guardrail = DeletionGuard(roots: options.scanRoots, home: options.home, environment: environment)
        let terraformVersions = options.terraformDirs.map(TerraformUsage.referencedVersions)

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
                items: (items(for: definition, roots: roots, index: index, now: options.now, inUse: inUse, guardrail: guardrail,
                              terraformVersions: terraformVersions)
                    + leftovers(for: definition, roots: roots, index: index)).sorted { $0.bytes > $1.bytes }
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

    static func items(
        for definition: CacheDefinition, roots: [DirectoryNode], index: TreeIndex, now: Date,
        inUse: InUseIndex = .empty, guardrail: DeletionGuard = DeletionGuard(roots: []), terraformVersions: Set<String>? = nil
    ) -> [CacheItem] {
        guard let rule = definition.itemRule else { return [] }
        let multipleRoots = roots.count > 1
        var candidates: [ItemCandidate] = []
        let depth: Int
        switch rule {
        case .versions(let ruleDepth, _, _): depth = ruleDepth
        case .projects: depth = 1
        case .terraformProviders: depth = 4
        case .largeChildren(let minimumBytes):
            return largeChildren(definition, minimumBytes: minimumBytes, roots: roots, index: index)
        case .cargoProfiles(let buildDirDepth):
            return cargoItems(definition, buildDirDepth: buildDirDepth, roots: roots, index: index, inUse: inUse, guardrail: guardrail)
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
        case .terraformProviders:
            marks = providerVersions(candidates, roots: roots, used: terraformVersions, now: now)
        case .cargoProfiles, .largeChildren:
            marks = [:]
        }
        return candidates.map { candidate in
            let mark = marks[candidate.id]
            // Old versions and stale projects cost a re-download or rebuild: suggested, never preselected.
            return CacheItem(
                id: candidate.id, entryID: definition.id, name: candidate.name, path: candidate.node.path,
                bytes: candidate.node.total.bytes, hardlinkedBytes: candidate.node.total.hardlinkedBytes,
                lastUsedAt: candidate.lastUsedAt, isRecommended: mark?.recommended ?? false, reason: mark?.reason
            )
        }
    }

    /// `.diskcare-deleting-*` directories left by an interrupted cleanup: always worth finishing.
    static func leftovers(for definition: CacheDefinition, roots: [DirectoryNode], index: TreeIndex) -> [CacheItem] {
        guard definition.safety.isCleanable else { return [] }
        let multipleRoots = roots.count > 1
        return roots.flatMap { root in
            index.descendants(of: root, upTo: TreeIndex.defaultDepth)
                .filter { Cleaner.isStagingName(($0.path as NSString).lastPathComponent) }
                .map { node in
                    let relative = String(node.path.dropFirst(root.path.count + 1))
                    let name = (multipleRoots ? (root.path as NSString).lastPathComponent + "/" : "") + relative
                    return CacheItem(
                        id: definition.id + "/" + name, entryID: definition.id, name: name, path: node.path,
                        bytes: node.total.bytes, hardlinkedBytes: node.total.hardlinkedBytes, lastUsedAt: nil,
                        isRecommended: true, isPreselectable: true, reason: "left over from an interrupted cleanup"
                    )
                }
        }
    }

    /// Big application data folders, listed so a full disk is explained; never cleanable.
    static func largeChildren(_ definition: CacheDefinition, minimumBytes: Int64, roots: [DirectoryNode], index: TreeIndex) -> [CacheItem] {
        roots.flatMap { root in
            index.descendants(of: root, depth: 1).filter { $0.total.bytes >= minimumBytes }.map { node in
                let name = (node.path as NSString).lastPathComponent
                return CacheItem(
                    id: definition.id + "/" + name, entryID: definition.id, name: name, path: node.path,
                    bytes: node.total.bytes, hardlinkedBytes: node.total.hardlinkedBytes,
                    lastUsedAt: date(node.total.latestModification), isRecommended: false,
                    reason: "app data: clean it up from inside the app", blockedReason: "holds application data"
                )
            }
        }
    }

    /// Cargo build dirs: every profile's `incremental` dir is a pure cache (recommended); a whole
    /// profile also drops `deps` and forces a full rebuild, so it is only ever picked by hand.
    static func cargoItems(
        _ definition: CacheDefinition, buildDirDepth: Int, roots: [DirectoryNode], index: TreeIndex,
        inUse: InUseIndex, guardrail: DeletionGuard
    ) -> [CacheItem] {
        let multipleRoots = roots.count > 1
        var items: [CacheItem] = []
        for root in roots {
            let buildDirs = buildDirDepth == 0 ? [root] : index.descendants(of: root, depth: buildDirDepth)
            for buildDir in buildDirs {
                // The entry root passed the gate when the catalog was built; per-workspace dirs are checked here.
                let dirProblem = buildDirDepth == 0 ? nil : CargoBuildDirectory.gateProblem(buildDir.path, guardrail: guardrail)
                for profile in CargoBuildDirectory.profiles(in: buildDir.path) {
                    let profilePath = buildDir.path + "/" + profile
                    guard let profileNode = index.node(at: profilePath) else { continue }
                    var relative = String(profilePath.dropFirst(root.path.count + 1))
                    if multipleRoots { relative = (root.path as NSString).lastPathComponent + "/" + relative }
                    let lock = CargoBuildDirectory.lockFile(forItemAt: profilePath)
                    let hazard = CargoBuildDirectory.profileHazard(profilePath)
                    let references = inUse.referenceReasons(under: profilePath)
                    var notes = ["all of \(profile)'s output: full rebuild"]
                    if let warning = hazard.warning { notes.append(warning) }
                    notes += references
                    items.append(CacheItem(
                        id: definition.id + "/" + relative, entryID: definition.id, name: relative, path: profilePath,
                        bytes: profileNode.total.bytes, hardlinkedBytes: profileNode.total.hardlinkedBytes,
                        lastUsedAt: date(profileNode.total.latestModification), isRecommended: false, reason: notes.joined(separator: "; "),
                        blockedReason: dirProblem ?? hazard.blocker ?? inUse.runningReason(under: profilePath), lockFile: lock
                    ))
                    guard let incremental = index.node(at: profilePath + "/incremental") else { continue }
                    items.append(CacheItem(
                        id: definition.id + "/" + relative + "/incremental", entryID: definition.id, name: relative + "/incremental",
                        path: incremental.path, bytes: incremental.total.bytes, hardlinkedBytes: incremental.total.hardlinkedBytes,
                        lastUsedAt: date(incremental.total.latestModification), isRecommended: incremental.total.bytes > 0,
                        isPreselectable: true, reason: "incremental compilation cache: rebuilt on the next build",
                        blockedReason: dirProblem, lockFile: lock
                    ))
                }
            }
        }
        return items
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

    /// Older provider versions, recommended only when the scanned projects are known not to use them.
    static func providerVersions(_ candidates: [ItemCandidate], roots: [DirectoryNode], used: Set<String>?, now: Date) -> [String: Mark] {
        var marks = olderVersions(candidates, keep: 1, grouping: .parent, now: now)
        for candidate in candidates {
            guard let root = roots.first(where: { candidate.node.path.hasPrefix($0.path + "/") }) else { continue }
            let key = String(candidate.node.path.dropFirst(root.path.count + 1))
            guard let used else {
                if let mark = marks[candidate.id], mark.recommended {
                    marks[candidate.id] = Mark(reason: mark.reason + "; scan projects to see whether it is still used", recommended: false)
                }
                continue
            }
            if used.contains(key) {
                marks[candidate.id] = Mark(reason: "used by a scanned project (lock file or .terraform)", recommended: false)
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

    static let defaultDepth = 2

    /// Path → node for every indexed descendant.
    private let byPath: [String: Int]

    init(tree: ScanTree?, itemRoots: [String], maxDepth: Int = defaultDepth) {
        self.init(tree: tree, itemRoots: Dictionary(itemRoots.map { ($0, maxDepth) }, uniquingKeysWith: max))
    }

    /// `itemRoots`: root path → how many levels below it to index.
    init(tree: ScanTree?, itemRoots: [String: Int]) {
        nodes = tree?.nodes ?? []
        var roots: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() where node.parent < 0 {
            roots[node.path] = offset
        }
        self.roots = roots

        // Children always have larger ids than their parent, so one forward pass finds shallow descendants.
        // Depth is counted down: a node indexes children while it has levels left.
        var remaining: [Int32: Int] = [:]
        for (path, depth) in itemRoots {
            if let offset = roots[path] { remaining[nodes[offset].id] = depth }
        }
        var children: [Int32: [Int]] = [:]
        var byPath: [String: Int] = [:]
        for (offset, node) in nodes.enumerated() where node.parent >= 0 {
            guard let left = remaining[node.parent], left > 0 else { continue }
            remaining[node.id] = left - 1
            children[node.parent, default: []].append(offset)
            byPath[node.path] = offset
        }
        self.children = children
        self.byPath = byPath
    }

    func node(at path: String) -> DirectoryNode? {
        byPath[path].map { nodes[$0] } ?? root(at: path)
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

    /// Every indexed descendant from depth 1 to `depth`.
    func descendants(of node: DirectoryNode, upTo depth: Int) -> [DirectoryNode] {
        var level = [node]
        var all: [DirectoryNode] = []
        for _ in 0..<depth {
            level = level.flatMap { children[$0.id, default: []].map { nodes[$0] } }
            all += level
        }
        return all
    }
}
