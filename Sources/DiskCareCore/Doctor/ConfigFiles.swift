import Foundation

/// Line-based reader/merger for `~/.terraformrc` (HCL). Only top-level attributes are considered;
/// blocks such as `provider_installation { … }` are skipped by tracking brace depth.
enum TerraformRC {
    static let cacheDirKey = "plugin_cache_dir"
    static let lockFileKey = "plugin_cache_may_break_dependency_lock_file"
    static let defaultCacheDir = "$HOME/.terraform.d/plugin-cache"

    /// Raw value of a top-level attribute, quotes removed.
    static func value(of key: String, in text: String) -> String? {
        var depth = 0
        for rawLine in text.components(separatedBy: "\n") {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if depth == 0, let (name, value) = attribute(line), name == key {
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            depth = max(0, depth)
        }
        return nil
    }

    /// Appends missing keys; existing values (even a different cache dir) are kept. nil = nothing to add.
    static func merged(_ text: String?) -> String? {
        let original = text ?? ""
        var additions: [String] = []
        if value(of: cacheDirKey, in: original) == nil {
            additions.append("\(cacheDirKey) = \"\(defaultCacheDir)\"")
        }
        if value(of: lockFileKey, in: original) == nil {
            additions.append("\(lockFileKey) = true")
        }
        guard !additions.isEmpty else { return nil }
        var result = original
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty && !result.hasSuffix("\n\n") { result += "\n" }
        result += "# Added by diskcare doctor: share provider binaries across all Terraform working dirs.\n"
        result += additions.joined(separator: "\n") + "\n"
        return result
    }

    /// Expands `$HOME` / `${HOME}` / `~` the way Terraform does for `plugin_cache_dir`.
    static func expand(_ path: String, home: String) -> String {
        var path = path.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if path.hasPrefix("~/") { path = home + path.dropFirst() }
        return path
    }

    private static func stripComment(_ line: String) -> String {
        var inString = false
        var previous: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" && previous != "\\" { inString.toggle() }
            if !inString {
                if character == "#" { return String(line[..<index]) }
                if character == "/" && previous == "/" { return String(line[..<line.index(before: index)]) }
            }
            previous = character
        }
        return line
    }

    private static func attribute(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return nil }
        return (name, String(line[line.index(after: equals)...]))
    }
}

/// Line-based reader/merger for Cargo's `config.toml`, aware of tables and dotted keys.
enum CargoConfig {
    /// `build.target-dir`, whether written as `[build] target-dir`, `build.target-dir` or `build = { target-dir = … }`.
    static func targetDir(in text: String) -> String? {
        var table = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if let header = tableHeader(line) {
                table = header
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = normalizeKey(String(line[..<equals]))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let fullKey = table.isEmpty ? key : table + "." + key
            if fullKey == "build.target-dir" { return unquote(value) }
            if fullKey == "build", value.hasPrefix("{"), let range = value.range(of: #"target-dir\s*=\s*"[^"]*""#, options: .regularExpression) {
                return unquote(String(value[range].split(separator: "=", maxSplits: 1)[1]))
            }
        }
        return nil
    }

    /// Adds `target-dir` under an existing `[build]` table, or appends a new table. nil = already set.
    static func merged(_ text: String?, targetDir: String) -> String? {
        let original = text ?? ""
        guard self.targetDir(in: original) == nil else { return nil }
        let entry = "target-dir = \"\(targetDir)\"  # shared by all projects (added by diskcare doctor)"
        var lines = original.components(separatedBy: "\n")
        if let header = lines.firstIndex(where: { tableHeader(stripComment($0).trimmingCharacters(in: .whitespaces)) == "build" }) {
            lines.insert(entry, at: header + 1)
            return lines.joined(separator: "\n")
        }
        var result = original
        if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }
        if !result.isEmpty && !result.hasSuffix("\n\n") { result += "\n" }
        return result + "[build]\n" + entry + "\n"
    }

    /// `[build]` → "build"; array tables (`[[bin]]`) are returned too so their keys are not mistaken for top-level ones.
    private static func tableHeader(_ line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return name.split(separator: ".").map { normalizeKey(String($0)) }.joined(separator: ".")
    }

    private static func normalizeKey(_ key: String) -> String {
        key.split(separator: ".").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }.joined(separator: ".")
    }

    private static func unquote(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }

    private static func stripComment(_ line: String) -> String {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" || character == "'" {
                if quote == nil { quote = character } else if quote == character { quote = nil }
            } else if character == "#" && quote == nil {
                return String(line[..<index])
            }
        }
        return line
    }
}
