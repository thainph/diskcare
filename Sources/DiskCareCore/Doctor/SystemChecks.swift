import Foundation

/// BuildKit keeps build cache forever unless garbage collection is configured in the daemon config.
public struct DockerBuildCacheGCCheck: DoctorCheck {
    public let id = "docker-build-cache-gc"
    public let title = "Docker build cache garbage collection"

    public init() {}

    static let snippet = #"{ "builder": { "gc": { "enabled": true, "defaultKeepStorage": "20GB" } } }"#

    struct Runtime {
        let name: String
        let configPath: String
        let howToEdit: String
    }

    func runtimes(_ context: DoctorContext) -> [Runtime] {
        var runtimes: [Runtime] = []
        if context.fileExists(context.home + "/.orbstack") {
            runtimes.append(Runtime(
                name: "OrbStack", configPath: context.home + "/.orbstack/config/docker.json",
                howToEdit: "OrbStack → Settings → Docker (or edit the file, then `orb restart docker`)"
            ))
        }
        if context.fileExists(context.home + "/.docker/daemon.json") || context.fileExists("/Applications/Docker.app") {
            runtimes.append(Runtime(
                name: "Docker Desktop", configPath: context.home + "/.docker/daemon.json",
                howToEdit: "Docker Desktop → Settings → Docker Engine"
            ))
        }
        return runtimes
    }

    /// `builder.gc` settings from a daemon.json-style file; nil when absent or unreadable.
    static func gcSettings(_ text: String) -> (enabled: Bool?, keepStorage: String?)? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let builder = object["builder"] as? [String: Any],
              let gc = builder["gc"] as? [String: Any] else { return nil }
        return (gc["enabled"] as? Bool, gc["defaultKeepStorage"] as? String)
    }

    public func evaluate(_ context: DoctorContext) -> CheckResult {
        let runtimes = runtimes(context)
        guard !runtimes.isEmpty else {
            return CheckResult(id: id, title: title, status: .ok, finding: "No OrbStack or Docker Desktop installation found.")
        }
        var details: [String] = []
        var configured: [String] = []
        var missing: [Runtime] = []
        for runtime in runtimes {
            let gc = context.read(runtime.configPath).flatMap(Self.gcSettings)
            if let gc, gc.enabled != false, gc.keepStorage != nil {
                configured.append(runtime.name)
                details.append("\(runtime.name): builder.gc enabled, defaultKeepStorage \(gc.keepStorage!) (\(runtime.configPath.abbreviatingHome))")
            } else {
                missing.append(runtime)
                details.append("\(runtime.name): no builder.gc.defaultKeepStorage in \(runtime.configPath.abbreviatingHome)")
            }
        }
        guard !missing.isEmpty else {
            return CheckResult(id: id, title: title, status: .ok, finding: "Build cache GC is configured (\(configured.joined(separator: ", "))).", details: details)
        }
        return CheckResult(
            id: id, title: title, status: .info,
            finding: "Build cache is not capped for \(missing.map(\.name).joined(separator: ", ")); BuildKit cache grows until pruned manually.",
            details: details,
            fix: "Merge \(Self.snippet) into the engine config via " + missing.map(\.howToEdit).joined(separator: "; ")
                + ". One-off: `docker builder prune --keep-storage 20GB`."
        )
    }
}

/// Local Time Machine snapshots hold deleted files' blocks, so cleaning may not show up as free space immediately.
public struct TimeMachineSnapshotsCheck: DoctorCheck {
    public let id = "time-machine-local-snapshots"
    public let title = "Time Machine local snapshots"

    public init() {}

    static func snapshotCount(_ output: String) -> Int {
        output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine.") }.count
    }

    public func evaluate(_ context: DoctorContext) -> CheckResult {
        guard let output = context.runCommand("/usr/bin/tmutil", ["listlocalsnapshots", "/"], 10) else {
            return CheckResult(id: id, title: title, status: .info, finding: "Could not list local snapshots (`tmutil listlocalsnapshots /` failed).")
        }
        let count = Self.snapshotCount(output)
        guard count > 0 else {
            return CheckResult(id: id, title: title, status: .ok, finding: "No local Time Machine snapshots.")
        }
        return CheckResult(
            id: id, title: title, status: .info,
            finding: "\(count) local snapshot\(count == 1 ? "" : "s") on /: space freed by deleting files stays used until they expire (macOS purges them when space runs low).",
            details: output.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine.") }.suffix(5).map(String.init),
            fix: "To reclaim now: `tmutil thinlocalsnapshots / 999999999999 4` (or `sudo tmutil deletelocalsnapshots /`)."
        )
    }
}
