import AppKit
import DiskCareCore
import SwiftUI

/// Where reclaimable space comes from. One color per source, used consistently in bars, legends and sidebar.
enum SpaceSource: String, CaseIterable, Identifiable {
    case projects, caches, docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: L("Project build files", "File build của dự án")
        case .caches: L("Developer caches", "Cache cho lập trình")
        case .docker: "Docker"
        }
    }

    /// Plain-language explanation shown under the title.
    var explanation: String {
        switch self {
        case .projects: L("node_modules, .terraform, build output of projects you haven't touched recently",
                          "node_modules, .terraform, output build của dự án lâu không đụng tới")
        case .caches: L("Package manager, browser and Xcode caches that tools re-download when needed",
                        "Cache của trình quản lý gói, trình duyệt và Xcode, công cụ tự tải lại khi cần")
        case .docker: L("Unused images, build cache and stopped containers (volumes with data are listed separately)",
                        "Image không dùng, build cache và container đã dừng (volume có dữ liệu được liệt kê riêng)")
        }
    }

    var systemImage: String {
        switch self {
        case .projects: "folder"
        case .caches: "archivebox"
        case .docker: "shippingbox"
        }
    }

    var color: Color {
        switch self {
        case .projects: .blue
        case .caches: .purple
        case .docker: .teal
        }
    }

    var section: MainSection { .cleanup }

    var filter: CleanupFilter {
        switch self {
        case .projects: .projects
        case .caches: .caches
        case .docker: .docker
        }
    }
}

/// Consistent page header: title, one-line purpose, headline number and the page's primary action.
struct PageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    var value: String?
    var valueCaption: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let value {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    if let valueCaption {
                        Text(valueCaption).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            actions()
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, subtitle: String, value: String? = nil, valueCaption: String? = nil) {
        self.init(title: title, subtitle: subtitle, value: value, valueCaption: valueCaption) { EmptyView() }
    }
}

/// Card container with an optional title, used for every content block in the main window.
/// Content sits on a mostly opaque layer so text keeps its contrast over the translucent window;
/// controls that float above content (sidebar, toolbar, action bar) use real Liquid Glass.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentSurface(cornerRadius: Metrics.cardRadius)
    }
}

enum Metrics {
    static let cardRadius: CGFloat = 18
    static let pagePadding: CGFloat = 24
}

extension View {
    /// Solid-enough surface for readable content (cards, lists).
    func contentSurface(cornerRadius: CGFloat = Metrics.cardRadius) -> some View {
        background(.background.opacity(0.78), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }

    /// Liquid Glass on macOS 26, a thin material before it: for controls floating above content.
    @ViewBuilder
    func glassSurface(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
    }

    /// The page's main action: prominent glass button on macOS 26.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryActionStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

/// How safe it is to clean something; drives grouping, preselection and confirmation everywhere.
enum SafetyTier: Int, CaseIterable, Identifiable {
    /// Re-created automatically (pure caches): preselected.
    case safe
    /// Needs a re-download or rebuild: picked by hand, confirmed once.
    case rebuild
    /// Never cleaned by DiskCare.
    case reportOnly

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .safe: L("Safe", "An toàn")
        case .rebuild: L("Needs re-download or rebuild", "Cần tải lại hoặc build lại")
        case .reportOnly: L("Report only", "Chỉ xem")
        }
    }

    var badge: String {
        switch self {
        case .safe: L("Re-created automatically", "Tự tạo lại")
        case .rebuild: L("Pick by hand", "Chọn thủ công")
        case .reportOnly: L("Never cleaned by DiskCare", "DiskCare không bao giờ xoá")
        }
    }

    var color: Color {
        switch self {
        case .safe: .green
        case .rebuild: .orange
        case .reportOnly: .secondary
        }
    }
}

/// Disk state in words and color (color never alone).
struct StatusPill: View {
    let level: SpaceLevel

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    private var title: String {
        switch level {
        case .ok: L("Healthy", "Ổn định")
        case .low: L("Low on space", "Sắp đầy")
        case .critical: L("Critically low", "Gần hết chỗ")
        }
    }

    var color: Color {
        switch level {
        case .ok: .green
        case .low: .orange
        case .critical: .red
        }
    }
}

/// Ring showing the free share of the disk.
struct RingGauge: View {
    let freeBytes: Int64
    let totalBytes: Int64
    let level: SpaceLevel
    var size: CGFloat = 132
    var lineWidth: CGFloat = 14
    var showsLabel = true

    var body: some View {
        let fraction = totalBytes > 0 ? Double(freeBytes) / Double(totalBytes) : 0
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(StatusPill(level: level).color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsLabel {
                VStack(spacing: 0) {
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: size * 0.18, weight: .bold, design: .rounded))
                    Text(L("free", "trống")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(L("\(ByteFormat.string(freeBytes)) free of \(ByteFormat.string(totalBytes))",
                              "Còn trống \(ByteFormat.string(freeBytes)) trên \(ByteFormat.string(totalBytes))"))
    }
}

/// Small text badge; color is always paired with a label (never color alone).
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// Result feedback after an action (success or failure), dismissible.
struct StatusBanner: View {
    let message: String
    var isError = false
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .orange : .green)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help(L("Dismiss", "Đóng"))
            }
        }
        .padding(10)
        .background((isError ? Color.orange : Color.green).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Horizontal stacked bar of the startup disk: used (other), reclaimable per source, free.
/// A stacked bar is easier to read than a pie for part-to-whole with a legend.
struct DiskUsageBar: View {
    let totalBytes: Int64
    let freeBytes: Int64
    let reclaimable: [(SpaceSource, Int64)]
    var height: CGFloat = 14
    var showsLegend = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                HStack(spacing: 1) {
                    segment(Color.secondary.opacity(0.45), otherUsed, width: geometry.size.width)
                    ForEach(reclaimable, id: \.0) { source, bytes in
                        segment(source.color, bytes, width: geometry.size.width)
                    }
                    segment(Color.secondary.opacity(0.12), freeBytes, width: geometry.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: height / 3))
            }
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(L("Disk: \(ByteFormat.string(freeBytes)) free of \(ByteFormat.string(totalBytes))",
                                  "Ổ đĩa: trống \(ByteFormat.string(freeBytes)) trên \(ByteFormat.string(totalBytes))"))

            if showsLegend {
                HStack(spacing: 14) {
                    legend(Color.secondary.opacity(0.45), L("Other used", "Đã dùng khác"), otherUsed)
                    ForEach(reclaimable, id: \.0) { source, bytes in
                        legend(source.color, source.title, bytes)
                    }
                    legend(Color.secondary.opacity(0.2), L("Free", "Trống"), freeBytes)
                }
                .font(.caption)
            }
        }
    }

    private var otherUsed: Int64 {
        max(0, totalBytes - freeBytes - reclaimable.reduce(0) { $0 + $1.1 })
    }

    private func segment(_ color: Color, _ bytes: Int64, width: CGFloat) -> some View {
        let fraction = totalBytes > 0 ? CGFloat(bytes) / CGFloat(totalBytes) : 0
        return Rectangle().fill(color).frame(width: max(0, fraction * width - 1))
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(.secondary)
            Text(ByteFormat.string(bytes)).monospacedDigit()
        }
    }
}

/// Human wording for "days since last activity".
func idleText(_ days: Int?) -> String {
    guard let days else { return L("never used", "chưa dùng") }
    switch days {
    case 0: return L("active today", "dùng hôm nay")
    case 1: return L("unused 1 day", "1 ngày không dùng")
    case 2..<60: return L("unused \(days) days", "\(days) ngày không dùng")
    default: return L("unused \(days / 30) months", "\(days / 30) tháng không dùng")
    }
}

extension DockerReport {
    /// Space freed without any data risk: unused images, build cache, stopped containers, anonymous volumes.
    var safeReclaimableBytes: Int64 {
        guard available else { return 0 }
        let images = unusedImages.reduce(Int64(0)) { $0 + $1.uniqueBytes }
        let containers = stoppedContainers.reduce(Int64(0)) { $0 + $1.bytes }
        let anonymous = unusedVolumeGroups.filter(\.isAnonymous).reduce(Int64(0)) { $0 + $1.bytes }
        return images + buildCache.reclaimableBytes + containers + anonymous
    }

    /// Unused named volumes: reclaimable, but may hold data, so they need a decision.
    var dataVolumeBytes: Int64 {
        unusedVolumeGroups.filter { !$0.isAnonymous }.reduce(Int64(0)) { $0 + $1.bytes }
    }
}

/// Step-by-step scan progress: "Step 2 of 5 · Scanning ~/Workspace · 412,000 files".
struct ScanStatusView: View {
    let status: AppModel.ScanStatus
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: status.fraction)
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.25), value: status.fraction)
            HStack(spacing: 4) {
                Text(status.title).lineLimit(1).truncationMode(.middle)
                if !status.detail.isEmpty {
                    Text("· \(status.detail)").foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("\(status.step)/\(status.totalSteps)").foregroundStyle(.tertiary).monospacedDigit()
            }
            .font(compact ? .caption : .callout)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("Scan step \(status.step) of \(status.totalSteps): \(status.title)",
                              "Bước quét \(status.step)/\(status.totalSteps): \(status.title)"))
    }
}
