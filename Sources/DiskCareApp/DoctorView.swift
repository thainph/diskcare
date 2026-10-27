import DiskCareCore
import Observation
import SwiftUI

/// Runs doctor checks off the main thread and applies auto-fixes after confirmation.
@MainActor
@Observable
final class DoctorModel {
    private(set) var results: [CheckResult] = []
    private(set) var isRunning = false
    private(set) var message: String?
    /// Fix awaiting confirmation.
    var pendingChange: (checkID: String, change: ConfigChange)?

    private var lastReportDate: Date?

    func run(report: ScanReport?) {
        guard !isRunning else { return }
        isRunning = true
        lastReportDate = report?.scannedAt
        Task {
            results = await Task.detached(priority: .utility) {
                Doctor.run(DoctorContext(report: report))
            }.value
            isRunning = false
        }
    }

    /// Re-runs only when a newer scan arrives.
    func refreshIfNeeded(report: ScanReport?) {
        guard results.isEmpty || report?.scannedAt != lastReportDate else { return }
        run(report: report)
    }

    func proposeFix(_ checkID: String) {
        do {
            if let change = try Doctor.proposedChange(for: checkID) {
                pendingChange = (checkID, change)
            } else {
                message = "Already configured."
            }
        } catch {
            message = "\(error)"
        }
    }

    func applyPendingFix(report: ScanReport?) {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        do {
            let applied = try pending.change.apply()
            message = "Updated \(applied.path.abbreviatingHome)"
                + (applied.backupPath.map { " (backup: \(URL(fileURLWithPath: $0).lastPathComponent))" } ?? "")
                + (applied.followUp.first.map { ". Next: \($0)" } ?? "")
        } catch {
            message = "Fix failed: \(error)"
        }
        run(report: report)
    }
}

/// Prevention advisor: config checks with estimated savings and one-click fixes.
/// Self-contained: pass the latest scan report; the view owns its model.
struct DoctorView: View {
    let report: ScanReport?
    @State private var model = DoctorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Doctor").font(.headline)
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
                Button {
                    model.run(report: report)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help("Run checks again")
            }
            if model.results.isEmpty {
                Text(model.isRunning ? "Checking…" : "No results yet").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.results) { result in
                            CheckRow(result: result) { model.proposeFix(result.id) }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .task(id: report?.scannedAt) { model.refreshIfNeeded(report: report) }
        .confirmationDialog(
            "Edit \(model.pendingChange?.change.path.abbreviatingHome ?? "config")?",
            isPresented: Binding(get: { model.pendingChange != nil }, set: { if !$0 { model.pendingChange = nil } })
        ) {
            Button("Write config") { model.applyPendingFix(report: report) }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmMessage: String {
        guard let change = model.pendingChange?.change else { return "" }
        let backup = change.originalContents == nil ? "The file will be created." : "The current file is backed up first."
        let added = change.newContents.split(separator: "\n").map(String.init)
            .filter { !(change.originalContents ?? "").split(separator: "\n").map(String.init).contains($0) }
        return backup + "\n\nAdds:\n" + added.joined(separator: "\n")
    }
}

private struct CheckRow: View {
    let result: CheckResult
    let onFix: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.title).fontWeight(.medium)
                    Spacer()
                    if let savings = result.estimatedSavingsBytes, savings > 0, result.status != .ok {
                        Text("~\(ByteFormat.string(savings))").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(result.finding).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if result.isAutoFixable {
                    Button("Fix…", action: onFix).controlSize(.small)
                } else if let fix = result.fix, result.status != .ok {
                    Text(fix).font(.caption2).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .help(result.details.joined(separator: "\n"))
    }

    private var icon: String {
        switch result.status {
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var color: Color {
        switch result.status {
        case .ok: .green
        case .warning: .orange
        case .info: .blue
        }
    }
}
