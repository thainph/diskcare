import Foundation

public enum CheckStatus: String, Sendable, Codable {
    /// Already configured; nothing to do.
    case ok
    /// Misconfiguration that wastes significant space.
    case warning
    /// Optional suggestion.
    case info
}

public struct CheckResult: Sendable, Codable, Identifiable {
    public let id: String
    public let title: String
    public let status: CheckStatus
    /// One-line summary of what was detected.
    public let finding: String
    /// Supporting facts (detected sources, projects, sizes…).
    public let details: [String]
    /// Space that the fix would save, when derivable from a scan report.
    public let estimatedSavingsBytes: Int64?
    /// What to do about it (shown even when not auto-fixable).
    public let fix: String?
    /// `Doctor.apply` can perform the fix by editing `fixTargetPath`.
    public let isAutoFixable: Bool
    public let fixTargetPath: String?

    public init(
        id: String, title: String, status: CheckStatus, finding: String, details: [String] = [],
        estimatedSavingsBytes: Int64? = nil, fix: String? = nil, isAutoFixable: Bool = false, fixTargetPath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.finding = finding
        self.details = details
        self.estimatedSavingsBytes = estimatedSavingsBytes
        self.fix = fix
        self.isAutoFixable = isAutoFixable
        self.fixTargetPath = fixTargetPath
    }
}

/// Runs an executable and returns trimmed stdout, or nil on failure, non-zero exit or timeout.
public typealias CommandRunner = @Sendable (_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> String?

/// Everything a check may look at. Injectable so tests never touch the real home directory.
public struct DoctorContext: Sendable {
    public var home: String
    public var environment: [String: String]
    public var report: ScanReport?
    /// Latest cache measurement: sizes of shared build dirs come from here instead of a rescan.
    public var cacheReport: CacheReport?
    public var runCommand: CommandRunner
    /// Measure directory sizes (e.g. the pnpm store); off in tests.
    public var measureSizes: Bool

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        report: ScanReport? = nil,
        cacheReport: CacheReport? = nil,
        runCommand: @escaping CommandRunner = ProcessRunner.run,
        measureSizes: Bool = true
    ) {
        self.home = home
        self.environment = environment
        self.report = report
        self.cacheReport = cacheReport
        self.runCommand = runCommand
        self.measureSizes = measureSizes
    }

    /// Files exporting `name`, e.g. `~/.zshrc: TF_PLUGIN_CACHE_DIR=…`.
    func shellExports(of name: String) -> [(file: String, value: String)] {
        ShellRC.exports(of: name, home: home)
    }

    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
}

/// Shell startup files, read-only. GUI apps do not inherit what they export, so DiskCare reads them.
enum ShellRC {
    static func files(home: String) -> [String] {
        [".zshenv", ".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"].map { home + "/" + $0 }
    }

    /// Files exporting `name`, e.g. `~/.zshrc: TF_PLUGIN_CACHE_DIR=…`, in the order the shell reads
    /// them; within a file the last assignment counts, as in the shell.
    static func exports(of name: String, home: String) -> [(file: String, value: String)] {
        files(home: home).compactMap { file in
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
            var found: String?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                var body = line.trimmingCharacters(in: .whitespaces)
                guard !body.hasPrefix("#") else { continue }
                if body.hasPrefix("export ") { body = body.dropFirst("export ".count).trimmingCharacters(in: .whitespaces) }
                guard body.hasPrefix(name + "=") else { continue }
                found = body.dropFirst(name.count + 1).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            }
            return found.map { (file, $0) }
        }
    }

    /// `name` from the environment, else the value the shell would end up with (last file exporting
    /// it, last assignment); `$HOME` expanded.
    static func value(of name: String, environment: [String: String], home: String) -> String? {
        if let value = environment[name], !value.isEmpty { return value }
        guard let value = exports(of: name, home: home).last?.value, !value.isEmpty else { return nil }
        return value.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
    }
}

/// A pluggable doctor check. Checks must be read-only in `evaluate`.
public protocol DoctorCheck: Sendable {
    var id: String { get }
    var title: String { get }
    /// Whether `proposedChange` can ever return an edit.
    var supportsAutoFix: Bool { get }
    func evaluate(_ context: DoctorContext) -> CheckResult
    /// The config edit that fixes the problem, or nil when nothing needs to change / not auto-fixable.
    func proposedChange(_ context: DoctorContext) throws -> ConfigChange?
    /// Directories tools write to because of this check's configuration. Whatever doctor sets up,
    /// DiskCare must also measure: every one must be covered by a cache definition.
    func managedLocations(_ context: DoctorContext) -> [String]
}

extension DoctorCheck {
    public var supportsAutoFix: Bool { false }
    public func proposedChange(_ context: DoctorContext) throws -> ConfigChange? { nil }
    public func managedLocations(_ context: DoctorContext) -> [String] { [] }
}

public enum DoctorError: Error, Sendable, CustomStringConvertible {
    case unknownCheck(String)
    case notAutoFixable(String)
    case fileChangedSinceProposal(String)

    public var description: String {
        switch self {
        case .unknownCheck(let id): "unknown check: \(id) (available: \(Doctor.checks.map(\.id).joined(separator: ", ")))"
        case .notAutoFixable(let id): "\(id) has no automatic fix"
        case .fileChangedSinceProposal(let path): "\(path.abbreviatingHome) changed since the fix was proposed; re-run doctor"
        }
    }
}

public enum Doctor {
    public static let checks: [any DoctorCheck] = [
        TerraformPluginCacheCheck(),
        CargoBuildCacheCheck(),
        NpmToPnpmCheck(),
        PnpmGlobalVirtualStoreCheck(),
        DockerBuildCacheGCCheck(),
        TimeMachineSnapshotsCheck(),
    ]

    public static func run(report: ScanReport?) -> [CheckResult] {
        run(DoctorContext(report: report))
    }

    /// Evaluates every check in parallel (some shell out); results keep `checks` order.
    public static func run(_ context: DoctorContext, checks: [any DoctorCheck] = Doctor.checks) -> [CheckResult] {
        let results = LockedArray<CheckResult?>(repeating: nil, count: checks.count)
        DispatchQueue.concurrentPerform(iterations: checks.count) { index in
            results[index] = checks[index].evaluate(context)
        }
        return results.values.compactMap { $0 }
    }

    public static func check(_ id: String) throws -> any DoctorCheck {
        guard let check = checks.first(where: { $0.id == id }) else { throw DoctorError.unknownCheck(id) }
        return check
    }

    /// The edit `apply` would make; nil when already configured.
    public static func proposedChange(for checkID: String, context: DoctorContext = DoctorContext()) throws -> ConfigChange? {
        let check = try check(checkID)
        guard check.supportsAutoFix else { throw DoctorError.notAutoFixable(checkID) }
        return try check.proposedChange(context)
    }

    /// Applies an auto-fix: backs up the target file, then writes the merged config.
    /// Returns nil when nothing needed to change.
    @discardableResult
    public static func apply(_ checkID: String, context: DoctorContext = DoctorContext(), now: Date = Date()) throws -> AppliedChange? {
        guard let change = try proposedChange(for: checkID, context: context) else { return nil }
        return try change.apply(now: now)
    }
}
