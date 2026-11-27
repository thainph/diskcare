import AppKit
import DiskCareCore
import SwiftUI

/// One part of the "Where your space is" bar.
struct SpaceSegment: Identifiable {
    enum Kind: String {
        case applications, projects, appData, caches, docker, otherInHome, system, free
    }

    let kind: Kind
    let bytes: Int64

    var id: String { kind.rawValue }

    var title: String {
        switch kind {
        case .applications: L("Applications", "Ứng dụng")
        case .projects: L("Projects", "Dự án")
        case .appData: L("App data", "Dữ liệu ứng dụng")
        case .caches: L("Developer caches", "Cache lập trình")
        case .docker: "Docker"
        case .otherInHome: L("Other in home", "Khác trong thư mục nhà")
        case .system: L("System & not measured", "Hệ thống & chưa đo")
        case .free: L("Free", "Trống")
        }
    }

    var help: String {
        switch kind {
        case .applications: L("/Applications and Homebrew", "/Applications và Homebrew")
        case .projects: L("Everything inside your scan folders", "Toàn bộ thư mục dự án được quét")
        case .appData: L("~/Library/Application Support: chats, models, app projects. Report only.",
                         "~/Library/Application Support: tin nhắn, mô hình, dự án của ứng dụng. Chỉ xem.")
        case .caches: L("Package manager, browser and Xcode caches", "Cache của trình quản lý gói, trình duyệt và Xcode")
        case .docker: L("Images, containers, volumes and build cache", "Image, container, volume và build cache")
        case .otherInHome: L("Home folder outside projects and caches", "Thư mục nhà ngoài dự án và cache")
        case .system: L("macOS, other volumes, snapshots and anything not measured yet",
                        "macOS, các volume khác, snapshot và phần chưa đo")
        case .free: L("Free space right now", "Dung lượng đang trống")
        }
    }

    var color: Color {
        switch kind {
        case .applications: .indigo
        case .projects: SpaceSource.projects.color
        case .appData: .pink
        case .caches: SpaceSource.caches.color
        case .docker: SpaceSource.docker.color
        case .otherInHome: .gray
        case .system: Color.secondary.opacity(0.4)
        case .free: Color.secondary.opacity(0.14)
        }
    }

    /// Unmeasured space is striped so it reads differently from measured parts without relying on color.
    var isHatched: Bool { kind == .system }
}

/// What the Overview and the menu suggest doing next, one per safety tier.
struct OverviewSuggestion: Identifiable {
    enum Action {
        /// Select only safe caches and open the review sheet.
        case cleanSafely
        /// Open the Clean up page.
        case review
        /// Report only: reveal the folders.
        case showInFinder([String])
    }

    let tier: SafetyTier
    let bytes: Int64
    let title: String
    let detail: String
    let action: Action

    var id: Int { tier.rawValue }

    var tierLabel: String {
        switch tier {
        case .safe: L("Safe", "An toàn")
        case .rebuild: L("Re-download", "Cần tải lại")
        case .reportOnly: L("Report only", "Chỉ xem")
        }
    }

    var systemImage: String {
        switch tier {
        case .safe: "checkmark.shield"
        case .rebuild: "arrow.down.circle"
        case .reportOnly: "eye"
        }
    }

    var actionTitle: String {
        switch action {
        case .cleanSafely: L("Clean", "Dọn")
        case .review: L("Review", "Xem lại")
        case .showInFinder: L("Show in Finder", "Mở trong Finder")
        }
    }

    /// Where the menu sends the user for this suggestion.
    var section: MainSection {
        switch action {
        case .cleanSafely, .review: .cleanup
        case .showInFinder: .insights
        }
    }
}

extension AppModel {
    static let appDataEntryID = "app-data"

    /// Used space split by source, ending with free space; sums to the disk size. Anything not measured
    /// yet (no explanation, Docker off) is folded into "System & not measured".
    var spaceBreakdown: [SpaceSegment]? {
        guard let space else { return nil }
        let used = max(0, space.totalBytes - space.availableBytes)
        let cacheReport = caches.report
        let appData = cacheReport?.entry(id: Self.appDataEntryID)?.bytes ?? 0
        let explanation = explain.explanation
        var measured: [SpaceSegment] = [
            SpaceSegment(kind: .applications, bytes: explanation?.outsideHome.reduce(0) { $0 + $1.bytes } ?? 0),
            SpaceSegment(kind: .projects, bytes: report?.stats.bytes ?? 0),
            SpaceSegment(kind: .appData, bytes: appData),
            SpaceSegment(kind: .caches, bytes: max(0, (cacheReport?.totalBytes ?? 0) - appData)),
            SpaceSegment(kind: .docker, bytes: dockerReport.map { $0.available ? $0.totalBytes : 0 } ?? 0),
            SpaceSegment(kind: .otherInHome, bytes: explanation?.exploredBytes ?? 0),
        ].filter { $0.bytes > 0 }
        // Never let measurements overlapping each other overflow the used space.
        var remaining = used
        measured = measured.map { segment in
            let bytes = min(segment.bytes, remaining)
            remaining -= bytes
            return SpaceSegment(kind: segment.kind, bytes: bytes)
        }
        return measured + [
            SpaceSegment(kind: .system, bytes: remaining),
            SpaceSegment(kind: .free, bytes: space.availableBytes),
        ]
    }

    /// "Warns below 74 GB (15%) · critical below 40 GB".
    var thresholdText: String? {
        guard let space else { return nil }
        let thresholds = settings.spaceThresholds
        let low = ByteFormat.string(thresholds.lowBytes(total: space.totalBytes))
        let critical = ByteFormat.string(thresholds.criticalBytes(total: space.totalBytes))
        let percent = Int(thresholds.lowPercent.rounded())
        return L("Warns below \(low) (\(percent)%) · critical below \(critical)",
                 "Cảnh báo khi dưới \(low) (\(percent)%) · nguy cấp khi dưới \(critical)")
    }

    /// Forecast when the disk fills soon, otherwise the weekly trend; nil without enough samples.
    var trendText: String? {
        if let forecastText { return forecastText }
        guard let perDay = forecast?.bytesPerDay else { return nil }
        let rate = ByteFormat.string(Int64(abs(perDay)))
        if abs(perDay) < 200_000_000 { return L("Free space is steady", "Dung lượng trống ổn định") }
        return perDay < 0
            ? L("Free space falls by about \(rate) a day", "Dung lượng trống giảm khoảng \(rate) mỗi ngày")
            : L("Free space grows by about \(rate) a day", "Dung lượng trống tăng khoảng \(rate) mỗi ngày")
    }

    var safeCleanTitle: String {
        L("Clean \(ByteFormat.string(safeCleanBytes)) safely", "Dọn an toàn \(ByteFormat.string(safeCleanBytes))")
    }

    /// At most one suggestion per tier, in tier order; tiers with nothing to show are left out.
    var suggestions: [OverviewSuggestion] {
        [safeSuggestion, rebuildSuggestion, appDataSuggestion].compactMap { $0 }
    }

    private var safeSuggestion: OverviewSuggestion? {
        guard let cacheReport = caches.report, safeCleanBytes > 0 else { return nil }
        // Largest safe caches first, by entry title ("npm, Chrome, uv…").
        var bytesByEntry: [String: Int64] = [:]
        for id in cacheReport.allSafeIDs {
            if let entry = cacheReport.entry(id: id) {
                bytesByEntry[entry.title, default: 0] += entry.bytes
            } else if let item = cacheReport.item(id: id), let entry = cacheReport.entry(id: item.entryID) {
                bytesByEntry[entry.title, default: 0] += item.bytes
            }
        }
        let names = bytesByEntry.sorted { $0.value > $1.value }.map(\.key)
        let list = Self.shortList(names, limit: 4)
        return OverviewSuggestion(
            tier: .safe, bytes: safeCleanBytes,
            title: L("Developer caches", "Cache lập trình"),
            detail: L("\(list). Re-created automatically.", "\(list). Tự tạo lại khi cần."),
            action: .cleanSafely
        )
    }

    /// The largest group that needs a re-download or rebuild: one cache's old items, or the project plan.
    private var rebuildSuggestion: OverviewSuggestion? {
        var best: OverviewSuggestion?
        for entry in caches.report?.entries ?? [] where entry.safety == .regenerable {
            let items = entry.recommendedItems.filter { !$0.isPreselectable }
            let bytes = items.reduce(Int64(0)) { $0 + $1.bytes }
            guard bytes > (best?.bytes ?? 0) else { continue }
            let names = Self.shortList(items.map(\.name), limit: 3)
            best = OverviewSuggestion(
                tier: .rebuild, bytes: bytes,
                title: L("Old \(entry.title)", "\(entry.title) cũ"),
                detail: L("\(items.count) unused: \(names). Downloaded again if needed.",
                          "\(items.count) mục không dùng: \(names). Sẽ tải lại nếu cần."),
                action: .review
            )
        }
        if planBytes > (best?.bytes ?? 0) {
            let days = settings.idleDays
            best = OverviewSuggestion(
                tier: .rebuild, bytes: planBytes,
                title: L("Project build files", "File build của dự án"),
                detail: L("\(plan.count) \(plan.count == 1 ? "folder" : "folders") in projects untouched for \(days)+ days. Rebuilt on next install or build.",
                          "\(plan.count) thư mục trong dự án hơn \(days) ngày không đụng tới. Build lại khi cài hoặc build lần sau."),
                action: .review
            )
        }
        return best
    }

    /// Big app data DiskCare never cleans: shown so the user knows where the space is.
    private var appDataSuggestion: OverviewSuggestion? {
        guard let entry = caches.report?.entry(id: Self.appDataEntryID), entry.bytes >= 1_000_000_000 else { return nil }
        let top = entry.items.prefix(2)
        let detail = top.isEmpty
            ? L("Apps' own data. Clean it from inside each app.", "Dữ liệu riêng của ứng dụng. Hãy dọn từ bên trong từng ứng dụng.")
            : L("\(top.map { "\($0.name) \(ByteFormat.string($0.bytes))" }.joined(separator: ", ")). Clean these from inside each app.",
                "\(top.map { "\($0.name) \(ByteFormat.string($0.bytes))" }.joined(separator: ", ")). Hãy dọn từ bên trong từng ứng dụng.")
        return OverviewSuggestion(
            tier: .reportOnly, bytes: entry.bytes,
            title: L("Big app data", "Dữ liệu ứng dụng lớn"),
            detail: detail,
            action: .showInFinder(top.isEmpty ? entry.paths : top.map(\.path))
        )
    }

    /// "npm, uv, Cargo and 3 more".
    private static func shortList(_ names: [String], limit: Int) -> String {
        let shown = names.prefix(limit).joined(separator: ", ")
        guard names.count > limit else { return shown }
        return L("\(shown) and \(names.count - limit) more", "\(shown) và \(names.count - limit) mục khác")
    }

    /// Runs a suggestion's action in the main window.
    func perform(_ suggestion: OverviewSuggestion) {
        switch suggestion.action {
        case .cleanSafely: reviewSafeClean()
        case .review: selectedSection = .cleanup
        case .showInFinder(let paths): NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) })
        }
    }
}
