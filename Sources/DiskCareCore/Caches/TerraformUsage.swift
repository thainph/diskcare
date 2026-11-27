import Foundation

/// Provider versions used by Terraform working dirs, as `<host>/<namespace>/<name>/<version>`
/// (the plugin cache's own layout).
public enum TerraformUsage {
    /// `workingDirs`: `.terraform` directories found by a project scan. Their lock files and their
    /// `providers/` links both count, since either may be newer than the other.
    public static func referencedVersions(terraformDirs: [String]) -> Set<String> {
        var versions = Set<String>()
        for directory in terraformDirs {
            let project = (directory as NSString).deletingLastPathComponent
            if let text = try? String(contentsOfFile: project + "/.terraform.lock.hcl", encoding: .utf8) {
                versions.formUnion(lockedVersions(in: text))
            }
            versions.formUnion(installedVersions(providersDirectory: directory + "/providers"))
        }
        return versions
    }

    /// `provider "registry.terraform.io/hashicorp/aws" { version = "6.62.0" … }`.
    static func lockedVersions(in text: String) -> Set<String> {
        let pattern = #"provider\s+"([^"]+)"\s*\{[^}]*?version\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            guard let source = Range(match.range(at: 1), in: text), let version = Range(match.range(at: 2), in: text) else { return nil }
            return "\(text[source])/\(text[version])"
        })
    }

    /// `.terraform/providers/<host>/<namespace>/<name>/<version>/<platform>`.
    static func installedVersions(providersDirectory: String) -> Set<String> {
        var versions = Set<String>()
        let fm = FileManager.default
        for host in (try? fm.contentsOfDirectory(atPath: providersDirectory)) ?? [] {
            for namespace in (try? fm.contentsOfDirectory(atPath: providersDirectory + "/" + host)) ?? [] {
                for name in (try? fm.contentsOfDirectory(atPath: "\(providersDirectory)/\(host)/\(namespace)")) ?? [] {
                    for version in (try? fm.contentsOfDirectory(atPath: "\(providersDirectory)/\(host)/\(namespace)/\(name)")) ?? [] {
                        versions.insert("\(host)/\(namespace)/\(name)/\(version)")
                    }
                }
            }
        }
        return versions
    }
}
