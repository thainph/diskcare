import Darwin
import Foundation

/// Last check before DiskCare removes or empties a directory. Paths are compared by
/// `(st_dev, st_ino)`, never by string, so `/tmp` vs `/private/tmp`, letter case on APFS and
/// firmlink aliases (`/System/Volumes/Data/Users/…`) cannot slip past it.
public struct DeletionGuard: Sendable {
    struct FileID: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
    }

    /// Directories a removed path must lie strictly inside (scan roots, or a cache entry's paths).
    let roots: [FileID]
    /// Protected locations and every ancestor of them: never removed or emptied.
    let protectedChain: Set<FileID>
    /// The roots and every ancestor of them: never removed (emptying a root is allowed).
    let rootChain: Set<FileID>

    public init(roots: [String], home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        let rootIDs = roots.compactMap { Self.identity(followingLinks: $0) }
        self.roots = rootIDs
        rootChain = Set(roots.flatMap(Self.chain))
        protectedChain = Set(Self.protectedLocations(home: home, environment: environment).flatMap(Self.chain))
    }

    /// Broad locations that merely contain caches or projects. The real home is always included,
    /// even when callers (tests) pass another one.
    static func protectedLocations(home: String, environment: [String: String]) -> [String] {
        var homes = [home]
        let realHome = NSHomeDirectory()
        if realHome != home { homes.append(realHome) }
        var paths = ["/", "/Users", "/Applications", "/Library", "/System", "/Volumes", "/private", "/tmp", "/var"]
        for home in homes {
            paths += [home, home + "/Library", home + "/Library/Caches", home + "/Library/Application Support",
                      home + "/Library/Developer", home + "/.cache", home + "/.config", home + "/.local",
                      home + "/.local/share", home + "/.cargo", home + "/.terraform.d", home + "/.docker", home + "/.ssh"]
        }
        if let cargoHome = environment["CARGO_HOME"], cargoHome.hasPrefix("/") { paths.append(cargoHome) }
        return paths
    }

    /// Why `path` must not be removed (nil = allowed): it must be an existing real directory strictly
    /// inside a root, and neither a protected location, a root, nor an ancestor of one.
    public func checkRemoval(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "path is not absolute" }
        guard let canonical = Self.canonicalDirectory(path) else {
            return insideRoots(Self.deepestExistingAncestor(of: path), includingSelf: true) ? Self.missingReason(path) : "outside scan roots"
        }
        guard let id = Self.identity(followingLinks: canonical) else { return "no longer exists" }
        guard insideRoots(canonical, includingSelf: false) else { return "outside scan roots" }
        if protectedChain.contains(id) { return "refusing to delete a protected location" }
        if rootChain.contains(id) { return "refusing to delete a scan root or its parent" }
        return nil
    }

    /// Why `path` must not be emptied (its children deleted, itself kept); nil = allowed.
    public func checkEmptying(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return "path is not absolute" }
        guard let canonical = Self.canonicalDirectory(path), let id = Self.identity(followingLinks: canonical) else {
            return Self.missingReason(path)
        }
        if protectedChain.contains(id) { return "refusing to empty a top-level directory" }
        guard canonical.split(separator: "/").count >= 3 else { return "path too shallow" }
        return nil
    }

    // MARK: Paths

    /// Whether `path` or (when `includingSelf` is false) one of its proper ancestors is a root.
    private func insideRoots(_ path: String?, includingSelf: Bool) -> Bool {
        guard var current = path else { return false }
        let roots = Set(self.roots)
        if !includingSelf {
            guard current != "/" else { return false }
            current = (current as NSString).deletingLastPathComponent
        }
        while true {
            if let id = Self.identity(followingLinks: current), roots.contains(id) { return true }
            if current == "/" { return false }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    private static func missingReason(_ path: String) -> String {
        var info = stat()
        guard lstat(path, &info) == 0 else { return "no longer exists" }
        return "not a directory (symlink?)"
    }

    /// The kernel's path for a real directory: intermediate links and firmlinks resolved, letter case
    /// as stored. nil when the path is missing, not a directory, or itself a symlink.
    static func canonicalDirectory(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func identity(followingLinks path: String) -> FileID? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileID(device: info.st_dev, inode: info.st_ino)
    }

    /// Identities of an existing path and all its ancestors (resolved through links).
    static func chain(_ path: String) -> [FileID] {
        guard let start = identity(followingLinks: path) else { return [] }
        var ids = [start]
        var current = canonicalTarget(path) ?? path
        while current != "/" {
            current = (current as NSString).deletingLastPathComponent
            if let id = identity(followingLinks: current) { ids.append(id) }
        }
        return ids
    }

    /// Canonical path of whatever `path` points to (links followed).
    private static func canonicalTarget(_ path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func deepestExistingAncestor(of path: String) -> String? {
        var current = (path as NSString).deletingLastPathComponent
        while !current.isEmpty {
            if let canonical = canonicalTarget(current) { return canonical }
            if current == "/" { return nil }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}
