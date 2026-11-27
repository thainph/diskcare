import AppKit
import DiskCareCore
import Observation
import SwiftUI

/// Runs the disk explorer: what fills the disk outside projects and known caches. Report only.
@MainActor
@Observable
final class ExplainModel {
    private(set) var explanation: DiskExplanation?
    private(set) var isRunning = false
    @ObservationIgnored private var progress: ScanProgress?

    func run(_ options: DiskExplorer.Options) async -> DiskExplanation? {
        guard !isRunning else { return nil }
        isRunning = true
        let progress = ScanProgress()
        self.progress = progress
        var options = options
        options.progress = progress
        let result: DiskExplanation = await DiskExplorer.explore(options)
        explanation = result
        isRunning = false
        self.progress = nil
        return result
    }

    func cancel() {
        progress?.cancel()
    }
}

/// "Where is the rest?": the largest folders no scan root or cache accounts for, the system share
/// nobody can measure and the Full Disk Access hint. Report only.
struct ExplainCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let explain = model.explain
        VStack(alignment: .leading, spacing: 10) {
            header(explain)
            if explain.isRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Reading your home folder outside projects and caches…", "Đang đọc thư mục nhà, ngoài dự án và cache…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let explanation = explain.explanation {
                rows(explanation)
                notes(explanation)
                if !explanation.notReadWithoutFullDiskAccess.isEmpty {
                    FullDiskAccessHint(folders: explanation.notReadWithoutFullDiskAccess)
                }
            } else if !explain.isRunning {
                Text(L("Finds large folders outside your projects and known caches. Nothing is deleted.",
                       "Tìm các thư mục lớn nằm ngoài dự án và cache đã biết. Không xoá gì cả."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(cornerRadius: Metrics.cardRadius)
    }

    private func header(_ explain: ExplainModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Label {
                Text(L("Where is the rest?", "Phần còn lại ở đâu?")).font(.headline)
            } icon: {
                Image(systemName: "questionmark.folder").foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let explanation = explain.explanation, !explain.isRunning {
                Text(readText(explanation)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if explain.isRunning {
                Button(L("Stop", "Dừng")) { explain.cancel() }
                    .secondaryActionStyle()
            } else if explain.explanation == nil {
                Button(L("Explain disk usage", "Phân tích dung lượng")) { run() }
                    .primaryActionStyle()
            } else {
                Button(L("Explain again", "Phân tích lại")) { run() }
                    .secondaryActionStyle()
            }
        }
    }

    @ViewBuilder
    private func rows(_ explanation: DiskExplanation) -> some View {
        VStack(spacing: 0) {
            if explanation.unexplained.isEmpty {
                Text(L("No folder above 1 GB outside projects and caches.", "Không có thư mục nào trên 1 GB ngoài dự án và cache."))
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            ForEach(explanation.unexplained, id: \.path) { row in
                if row.path != explanation.unexplained.first?.path { Divider() }
                folderRow(row)
            }
            if let unaccounted = explanation.unaccountedBytes, unaccounted > 0 {
                Divider()
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("System & not measured", "Hệ thống & không đo được"))
                        Text(systemExplanation(explanation)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text(ByteFormat.string(unaccounted)).font(.callout.weight(.semibold)).monospacedDigit()
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func folderRow(_ row: UnexplainedDirectory) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.path.abbreviatingHome + (row.isRemainder ? L(" (other files)", " (các file khác)") : ""))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if row.containsProjects {
                    Label(L("Contains git repositories", "Có kho git bên trong"), systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if row.containsProjects, !model.settings.roots.contains(row.path) {
                Button(L("Add to scan roots", "Thêm vào thư mục quét")) { model.settings.roots.append(row.path) }
                    .controlSize(.small)
                    .secondaryActionStyle()
                    .help(L("Scan this folder for projects from now on", "Từ nay quét cả thư mục này để tìm dự án"))
            }
            Text(ByteFormat.string(row.bytes)).font(.callout.weight(.semibold)).monospacedDigit()
            RevealInFinderButton(path: row.path)
        }
        .padding(.vertical, 8)
        .help(row.path)
    }

    /// Outside-home sizes and caveats, one line under the rows.
    @ViewBuilder
    private func notes(_ explanation: DiskExplanation) -> some View {
        let text = notesText(explanation)
        if !text.isEmpty {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func notesText(_ explanation: DiskExplanation) -> String {
        var parts: [String] = []
        let outside = explanation.outsideHome.filter { $0.bytes > 0 }
        if !outside.isEmpty {
            parts.append(L("Outside your home folder: ", "Ngoài thư mục nhà: ")
                + outside.map { "\($0.name) \(ByteFormat.string($0.bytes))" }.joined(separator: ", "))
        }
        if explanation.cancelled { parts.append(L("Stopped early: results are partial.", "Đã dừng giữa chừng: kết quả chưa đầy đủ.")) }
        return parts.joined(separator: " · ")
    }

    private func systemExplanation(_ explanation: DiskExplanation) -> String {
        var text = L("System files, VM disks inside app containers, privacy-protected folders",
                     "File hệ thống, ổ ảo trong container của ứng dụng, thư mục được bảo vệ quyền riêng tư")
        if let snapshots = explanation.localSnapshots, snapshots > 0 {
            text += L(", \(snapshots) local Time Machine snapshots", ", \(snapshots) bản chụp Time Machine cục bộ")
        }
        return text
    }

    /// "Read 5 min ago" in the interface language.
    private func readText(_ explanation: DiskExplanation) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.resolved.locale
        let age = formatter.localizedString(for: explanation.exploredAt, relativeTo: Date())
        return L("Read \(age)", "Đọc \(age)")
    }

    private func run() {
        Task { await model.explainDiskUsage(priority: .userInitiated) }
    }
}

/// Privacy folders were skipped: explain why and open the right Settings pane.
private struct FullDiskAccessHint: View {
    let folders: [String]

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(.tint).accessibilityHidden(true)
            Text(L("\(names) need Full Disk Access to be measured.", "\(names) cần quyền Truy cập toàn bộ ổ đĩa để đo được."))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(L("Open Privacy Settings", "Mở cài đặt Quyền riêng tư")) {
                NSWorkspace.shared.open(Self.settingsURL)
            }
            .secondaryActionStyle()
            .help(L("System Settings › Privacy & Security › Full Disk Access", "Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Truy cập toàn bộ ổ đĩa"))
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var names: String {
        let formatter = ListFormatter()
        formatter.locale = AppLanguage.resolved.locale
        let list = folders.map { URL(fileURLWithPath: $0).lastPathComponent }
        return formatter.string(from: list) ?? list.joined(separator: ", ")
    }
}
