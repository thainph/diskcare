import Foundation

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

public enum ByteFormat {
    /// Decimal units, matching Finder and `docker system df`.
    public static func string(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unit = 0
        while abs(value) >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        return unit == 0 ? "\(bytes) B" : String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[unit])
    }

    /// Parses sizes like "500MB", "1.5G", "200k" (decimal units).
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }
        let multiplier: Double
        switch trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces) {
        case "", "B": multiplier = 1
        case "K", "KB": multiplier = 1e3
        case "M", "MB": multiplier = 1e6
        case "G", "GB": multiplier = 1e9
        case "T", "TB": multiplier = 1e12
        default: return nil
        }
        return Int64(value * multiplier)
    }
}

extension String {
    /// Replaces the home directory prefix with `~` for display.
    public var abbreviatingHome: String {
        (self as NSString).abbreviatingWithTildeInPath
    }
}
