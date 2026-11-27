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
    private(set) var messageIsError = false
    /// Fix awaiting confirmation.
    var pendingChange: (checkID: String, change: ConfigChange)?

    /// Drives the confirmation dialog through a key path (see `AppModel` on closure bindings).
    var isConfirmingFix: Bool {
        get { pendingChange != nil }
        set { if !newValue { pendingChange = nil } }
    }

    private var lastReportDate: Date?

    func run(report: ScanReport?, caches: CacheReport? = nil) {
        guard !isRunning else { return }
        isRunning = true
        lastReportDate = report?.scannedAt
        Task {
            results = await Task.detached(priority: .utility) {
                Doctor.run(DoctorContext(report: report, cacheReport: caches))
            }.value
            isRunning = false
        }
    }

    /// Re-runs only when a newer scan arrives.
    func refreshIfNeeded(report: ScanReport?, caches: CacheReport?) {
        guard results.isEmpty || report?.scannedAt != lastReportDate else { return }
        run(report: report, caches: caches)
    }

    func proposeFix(_ checkID: String) {
        do {
            if let change = try Doctor.proposedChange(for: checkID) {
                pendingChange = (checkID, change)
            } else {
                message = L("Already configured.", "Đã được cấu hình.")
                messageIsError = false
            }
        } catch {
            message = "\(error)"
            messageIsError = true
        }
    }

    func applyPendingFix(report: ScanReport?) {
        guard let pending = pendingChange else { return }
        pendingChange = nil
        do {
            let applied = try pending.change.apply()
            message = L("Updated \(applied.path.abbreviatingHome)", "Đã cập nhật \(applied.path.abbreviatingHome)")
                + (applied.backupPath.map { L(" (backup: \(URL(fileURLWithPath: $0).lastPathComponent))", " (bản sao lưu: \(URL(fileURLWithPath: $0).lastPathComponent))") } ?? "")
                + (applied.followUp.first.map { L(". Next: \($0)", ". Bước tiếp: \($0)") } ?? "")
            messageIsError = false
        } catch {
            message = L("Fix failed: \(error)", "Sửa không thành công: \(error)")
            messageIsError = true
        }
        run(report: report)
    }
}

/// Prevention advisor: config checks with estimated savings and one-click fixes.
/// Self-contained: pass the latest scan report; the view owns its model.
struct DoctorView: View {
    let report: ScanReport?
    var caches: CacheReport?
    var showsHeader = true
    /// nil = no inner scroll view (the host page scrolls).
    var listMaxHeight: CGFloat? = 260
    @State private var model = DoctorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader { HStack {
                Text(L("Doctor", "Kiểm tra cấu hình")).font(.headline)
                Spacer()
                if model.isRunning { ProgressView().controlSize(.small) }
                Button {
                    model.run(report: report, caches: caches)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(model.isRunning)
                .help(L("Run checks again", "Kiểm tra lại"))
                .accessibilityLabel(L("Run checks again", "Kiểm tra lại"))
            } }
            if model.results.isEmpty {
                HStack(spacing: 8) {
                    if model.isRunning { ProgressView().controlSize(.small) }
                    Text(model.isRunning ? L("Checking…", "Đang kiểm tra…") : L("No results yet", "Chưa có kết quả"))
                }
                .font(.callout).foregroundStyle(.secondary)
            } else {
                let list = VStack(alignment: .leading, spacing: 0) {
                    ForEach(sortedResults) { result in
                        if result.id != sortedResults.first?.id { Divider() }
                        CheckRow(result: result) { model.proposeFix(result.id) }
                            .padding(.vertical, 10)
                    }
                }
                if let listMaxHeight {
                    ScrollView { list }.frame(maxHeight: listMaxHeight)
                } else {
                    list
                }
            }
            if let message = model.message {
                StatusBanner(message: message, isError: model.messageIsError)
            }
        }
        .task(id: report?.scannedAt) { model.refreshIfNeeded(report: report, caches: caches) }
        .confirmationDialog(
            L("Edit \(model.pendingChange?.change.path.abbreviatingHome ?? "config")?",
              "Sửa \(model.pendingChange?.change.path.abbreviatingHome ?? "cấu hình")?"),
            isPresented: Bindable(model).isConfirmingFix
        ) {
            Button(L("Write config", "Ghi cấu hình")) { model.applyPendingFix(report: report) }
        } message: {
            Text(confirmMessage)
        }
    }

    /// Actionable items first: warnings, then suggestions with savings, then OK.
    private var sortedResults: [CheckResult] {
        func rank(_ status: CheckStatus) -> Int {
            switch status {
            case .warning: 0
            case .info: 1
            case .ok: 2
            }
        }
        return model.results.sorted {
            (rank($0.status), -($0.estimatedSavingsBytes ?? 0)) < (rank($1.status), -($1.estimatedSavingsBytes ?? 0))
        }
    }

    private var confirmMessage: String {
        guard let change = model.pendingChange?.change else { return "" }
        let backup = change.originalContents == nil
            ? L("The file will be created.", "File sẽ được tạo mới.")
            : L("The current file is backed up first.", "File hiện tại sẽ được sao lưu trước.")
        let added = change.newContents.split(separator: "\n").map(String.init)
            .filter { !(change.originalContents ?? "").split(separator: "\n").map(String.init).contains($0) }
        return backup + L("\n\nAdds:\n", "\n\nThêm:\n") + added.joined(separator: "\n")
    }
}

private struct CheckRow: View {
    let result: CheckResult
    let onFix: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
                .accessibilityLabel(statusText)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(result.title).fontWeight(.medium)
                    Spacer()
                    if let savings = result.estimatedSavingsBytes, savings > 0, result.status != .ok {
                        Text(L("saves ~\(ByteFormat.string(savings))", "tiết kiệm ~\(ByteFormat.string(savings))"))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                Text(result.finding).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if result.isAutoFixable {
                    Button(L("Fix…", "Sửa…"), action: onFix)
                        .controlSize(.small)
                        .secondaryActionStyle()
                        .help(L("Shows the exact change and backs up the file first", "Hiện thay đổi cụ thể và sao lưu file trước"))
                } else if let fix = result.fix, result.status != .ok {
                    Text(fix).font(.caption).foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .help(result.details.joined(separator: "\n"))
    }

    private var statusText: String {
        switch result.status {
        case .ok: L("OK", "Ổn")
        case .warning: L("Warning", "Cảnh báo")
        case .info: L("Suggestion", "Gợi ý")
        }
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
