import ArgumentParser
import DiskCareCore
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check tool configuration that prevents disk waste (Terraform plugin cache, Cargo target dir, pnpm…).",
        discussion: """
        Examples:
          diskcare doctor ~/Workspace                     # scan for savings estimates, then run checks
          diskcare doctor --no-scan
          diskcare doctor --fix terraform-plugin-cache    # show the config diff, ask, then write it

        Checks: \(Doctor.checks.map(\.id).joined(separator: ", "))
        """
    )

    @OptionGroup var scan: ScanArguments

    @Flag(name: .long, help: "Skip the filesystem scan (no savings estimates).")
    var noScan = false

    @Option(name: .long, help: "Apply the automatic fix of a check (shows the diff and asks first).")
    var fix: String?

    @Flag(name: [.short, .long], help: "Do not ask for confirmation when fixing.")
    var yes = false

    @Flag(name: .long, help: "Print results as JSON.")
    var json = false

    func run() throws {
        if let fix {
            try applyFix(fix)
            return
        }
        let report = noScan ? nil : DiskAnalyzer.analyze(scan.options, inspectGit: false)
        let results = Doctor.run(DoctorContext(report: report))
        if json {
            try printJSON(results)
            return
        }
        if let report {
            print("Scanned \(report.roots.map(\.abbreviatingHome).joined(separator: ", ")) in \(String(format: "%.1f", report.stats.durationSeconds))s\n")
        }
        for result in results { printResult(result) }

        let savings = results.filter { $0.status != .ok }.compactMap(\.estimatedSavingsBytes).reduce(0, +)
        let warnings = results.filter { $0.status == .warning }.count
        print("\(warnings) warning\(warnings == 1 ? "" : "s"), \(results.filter { $0.status == .info }.count) suggestions"
            + (savings > 0 ? ", ~\(ByteFormat.string(savings)) avoidable" : ""))
    }

    private func printResult(_ result: CheckResult) {
        let badge = switch result.status {
        case .ok: "[ OK ]"
        case .warning: "[WARN]"
        case .info: "[INFO]"
        }
        print("\(badge) \(result.title) (\(result.id))")
        print("       \(result.finding)")
        for detail in result.details { print("         · \(detail)") }
        if let savings = result.estimatedSavingsBytes, savings > 0, result.status != .ok {
            print("       Estimated savings: ~\(ByteFormat.string(savings))")
        }
        if let fix = result.fix, result.status != .ok { print("       Fix: \(fix)") }
        if result.isAutoFixable { print("       Auto-fix: diskcare doctor --fix \(result.id)") }
        print()
    }

    private func applyFix(_ id: String) throws {
        let change: ConfigChange?
        do {
            change = try Doctor.proposedChange(for: id)
        } catch let error as DoctorError {
            FileHandle.standardError.write(Data("Error: \(error.description)\n".utf8))
            throw ExitCode(1)
        }
        guard let change else {
            print("\(id): nothing to change, already configured.")
            return
        }
        print(change.diff)
        if change.originalContents != nil {
            print("\nA backup will be written to \(change.path.abbreviatingHome).diskcare-backup-<timestamp>.")
        }
        for directory in change.directoriesToCreate where !FileManager.default.fileExists(atPath: directory) {
            print("Will create \(directory.abbreviatingHome).")
        }
        if !yes {
            print("\nWrite \(change.path.abbreviatingHome)? [y/N] ", terminator: "")
            let answer = readLine()?.lowercased()
            guard answer == "y" || answer == "yes" else {
                print("Aborted.")
                return
            }
        }
        let applied = try change.apply()
        print("Updated \(applied.path.abbreviatingHome)" + (applied.backupPath.map { " (backup: \($0.abbreviatingHome))" } ?? ""))
        for step in applied.followUp { print("  next: \(step)") }
    }
}
