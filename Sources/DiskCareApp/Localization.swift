import Foundation

/// Interface language. `system` follows macOS (Vietnamese when it is the first preferred language).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, english, vietnamese

    var id: String { rawValue }

    /// Shown in its own language so it can always be found.
    var title: String {
        switch self {
        case .system: L("System", "Theo hệ thống")
        case .english: "English"
        case .vietnamese: "Tiếng Việt"
        }
    }

    static let defaultsKey = "language"

    /// The language in effect right now.
    static var resolved: AppLanguage {
        let stored = UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        guard stored == .system else { return stored }
        return Locale.preferredLanguages.first?.hasPrefix("vi") == true ? .vietnamese : .english
    }

    var locale: Locale {
        Locale(identifier: Self.resolved == .vietnamese ? "vi_VN" : "en_US")
    }
}

/// Bilingual text: the English and Vietnamese wording side by side where they are used, so a
/// screen can never show a missing key. Views re-render on a language change because the window
/// roots are keyed by `AppSettings.language`.
func L(_ english: String, _ vietnamese: String) -> String {
    AppLanguage.resolved == .vietnamese ? vietnamese : english
}
