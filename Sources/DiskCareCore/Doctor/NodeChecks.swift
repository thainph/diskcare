import Foundation

/// npm and yarn (classic) copy every dependency into each project; pnpm hard-links from one store.
public struct NpmToPnpmCheck: DoctorCheck {
    public let id = "npm-to-pnpm"
    public let title = "npm/yarn projects that could use pnpm"

    public init() {}

    public struct Project: Sendable, Equatable {
        public let path: String
        public let manager: String
        public let nodeModulesBytes: Int64
    }

    /// Projects whose `node_modules` sits next to `package-lock.json` / `yarn.lock` but no `pnpm-lock.yaml`.
    public static func projects(in report: ScanReport, fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> [Project] {
        report.artifacts.compactMap { artifact in
            guard artifact.kind == .nodeModules else { return nil }
            let project = (artifact.path as NSString).deletingLastPathComponent
            guard !fileExists(project + "/pnpm-lock.yaml") else { return nil }
            let manager: String
            if fileExists(project + "/package-lock.json") {
                manager = "npm"
            } else if fileExists(project + "/yarn.lock") {
                manager = "yarn"
            } else {
                return nil
            }
            return Project(path: project, manager: manager, nodeModulesBytes: artifact.totals.bytes)
        }
        .sorted { $0.nodeModulesBytes > $1.nodeModulesBytes }
    }

    func storePath(_ context: DoctorContext) -> (path: String, fromPnpm: Bool) {
        if let pnpm = ProcessRunner.locate("pnpm", environment: context.environment, home: context.home),
           let path = context.runCommand(pnpm, ["store", "path"], 5)?.split(separator: "\n").last.map(String.init),
           path.hasPrefix("/") {
            return (path, true)
        }
        // pnpm's macOS default; the versioned subdirectory (v3, v10…) lives below it.
        return (context.home + "/Library/pnpm/store", false)
    }

    public func evaluate(_ context: DoctorContext) -> CheckResult {
        let store = storePath(context)
        var details: [String] = []
        if context.fileExists(store.path) || context.fileExists((store.path as NSString).deletingLastPathComponent) {
            let size = context.measureSizes ? storeSize(store.path) : nil
            details.append("pnpm store: \(store.path.abbreviatingHome)\(size.map { " (\(ByteFormat.string($0)))" } ?? "")\(store.fromPnpm ? "" : " (default location)")")
        } else {
            details.append("pnpm store: not found (expected at \(store.path.abbreviatingHome))")
        }

        guard let report = context.report else {
            return CheckResult(id: id, title: title, status: .info, finding: "Scan your projects to list npm/yarn projects.", details: details)
        }
        let projects = Self.projects(in: report, fileExists: context.fileExists)
        guard !projects.isEmpty else {
            return CheckResult(id: id, title: title, status: .ok, finding: "No npm/yarn projects with node_modules found.", details: details)
        }
        let total = projects.reduce(Int64(0)) { $0 + $1.nodeModulesBytes }
        let shown = 15
        details += projects.prefix(shown).map { "\(ByteFormat.string($0.nodeModulesBytes).padding(toLength: 8, withPad: " ", startingAt: 0)) \($0.manager.padding(toLength: 4, withPad: " ", startingAt: 0)) \($0.path.abbreviatingHome)" }
        if projects.count > shown { details.append("… and \(projects.count - shown) more") }
        return CheckResult(
            id: id, title: title, status: .info,
            finding: "\(projects.count) npm/yarn projects hold \(ByteFormat.string(total)) of node_modules that pnpm would hard-link from its shared store.",
            details: details,
            fix: "In each project: `pnpm import` (converts package-lock.json / yarn.lock to pnpm-lock.yaml), `rm -rf node_modules`, `pnpm install`; "
                + "then update CI and scripts. Only where the team agrees to switch package manager."
        )
    }

    private func storeSize(_ path: String) -> Int64? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return FileSystemScanner.scan(ScanOptions(roots: [path], priority: .background)).stats.bytes
    }
}

/// pnpm ≥ 10.12 can keep the virtual store (`node_modules/.pnpm`) globally, so projects only hold symlinks.
public struct PnpmGlobalVirtualStoreCheck: DoctorCheck {
    public let id = "pnpm-global-virtual-store"
    public let title = "pnpm global virtual store"

    public init() {}

    static let minimumVersion = [10, 12]
    static let setting = "enable-global-virtual-store"

    static func supports(version: String) -> Bool {
        let parts = version.split(separator: "-").first?.split(separator: ".").compactMap { Int($0) } ?? []
        guard parts.count >= 2 else { return false }
        return parts.lexicographicallyPrecedes(minimumVersion) == false
    }

    /// Global pnpm rc files (macOS default, XDG) and `~/.npmrc`.
    func configFiles(_ context: DoctorContext) -> [String] {
        let xdg = context.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? context.home + "/.config"
        return [context.home + "/Library/Preferences/pnpm/rc", xdg + "/pnpm/rc", context.home + "/.npmrc"]
    }

    public func evaluate(_ context: DoctorContext) -> CheckResult {
        let enabledIn = configFiles(context).first { file in
            context.read(file)?.split(separator: "\n").contains { line in
                let compact = line.replacingOccurrences(of: " ", with: "")
                return !compact.hasPrefix("#") && !compact.hasPrefix(";") && compact.hasPrefix(Self.setting + "=true")
            } ?? false
        }
        if let enabledIn {
            return CheckResult(id: id, title: title, status: .ok, finding: "\(Self.setting) is enabled in \(enabledIn.abbreviatingHome).")
        }
        guard let pnpm = ProcessRunner.locate("pnpm", environment: context.environment, home: context.home) else {
            return CheckResult(id: id, title: title, status: .info, finding: "pnpm not found on PATH; nothing to configure.")
        }
        guard let version = context.runCommand(pnpm, ["--version"], 5)?.split(separator: "\n").last.map(String.init) else {
            return CheckResult(id: id, title: title, status: .info, finding: "Could not read the pnpm version (\(pnpm.abbreviatingHome) --version failed or timed out).")
        }
        let details = ["pnpm \(version) at \(pnpm.abbreviatingHome)"]
        guard Self.supports(version: version) else {
            return CheckResult(
                id: id, title: title, status: .info,
                finding: "pnpm \(version) is installed; the global virtual store needs pnpm ≥ 10.12.",
                details: details,
                fix: "Upgrade pnpm (`pnpm self-update` or `corepack use pnpm@latest`), then consider `\(Self.setting)=true`."
            )
        }
        return CheckResult(
            id: id, title: title, status: .info,
            finding: "pnpm \(version) supports \(Self.setting) (experimental): node_modules would only contain symlinks into the store.",
            details: details,
            fix: "`pnpm config set \(Self.setting) true --location=global`, then `pnpm install` per project. Experimental: some tools that resolve real paths may break."
        )
    }
}
