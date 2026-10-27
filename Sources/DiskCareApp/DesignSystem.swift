import AppKit
import DiskCareCore
import SwiftUI

/// Where reclaimable space comes from. One color per source, used consistently in bars, legends and sidebar.
enum SpaceSource: String, CaseIterable, Identifiable {
    case projects, caches, docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projects: "Project build files"
        case .caches: "Developer caches"
        case .docker: "Docker"
        }
    }

    /// Plain-language explanation shown under the title.
    var explanation: String {
        switch self {
        case .projects: "node_modules, .terraform, build output of projects you haven't touched recently"
        case .caches: "Package manager, browser and Xcode caches that tools re-download when needed"
        case .docker: "Unused images, build cache and stopped containers (volumes with data are listed separately)"
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

    var section: MainSection {
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
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label {
                    Text(title).font(.headline)
                } icon: {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
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
                    .help("Dismiss")
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
            .accessibilityLabel("Disk: \(ByteFormat.string(freeBytes)) free of \(ByteFormat.string(totalBytes))")

            if showsLegend {
                HStack(spacing: 14) {
                    legend(Color.secondary.opacity(0.45), "Other used", otherUsed)
                    ForEach(reclaimable, id: \.0) { source, bytes in
                        legend(source.color, source.title, bytes)
                    }
                    legend(Color.secondary.opacity(0.2), "Free", freeBytes)
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
    guard let days else { return "never used" }
    switch days {
    case 0: return "active today"
    case 1: return "unused 1 day"
    case 2..<60: return "unused \(days) days"
    default: return "unused \(days / 30) months"
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
