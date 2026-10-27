/// A directory whose whole subtree is rolled up into one entry: either a regenerable
/// build/dependency artifact, or VCS metadata (measured but never cleaned).
public enum ArtifactKind: String, Codable, Sendable, CaseIterable {
    case nodeModules = "node_modules"
    case jsFrameworkBuild = "js-framework-build"   // .next, .nuxt, .svelte-kit, .output
    case jsToolCache = "js-tool-cache"             // .turbo, .parcel-cache, .angular
    case jsBuildOutput = "js-build-output"         // dist/build/coverage next to package.json
    case terraform = ".terraform"
    case terragruntCache = ".terragrunt-cache"
    case cargoTarget = "cargo-target"
    case pythonVenv = "python-venv"
    case pythonCache = "python-cache"
    case composerVendor = "composer-vendor"
    case cocoaPods = "cocoapods"
    case gradle = "gradle"
    case dartTool = "dart-tool"
    case xcodeDerivedData = "xcode-derived-data"
    case gitMetadata = ".git"

    /// Whether deleting it is safe because a tool can rebuild it.
    public var isRegenerable: Bool { self != .gitMetadata }

    /// Command that rebuilds the artifact, shown to the user before cleaning.
    public var restoreHint: String {
        switch self {
        case .nodeModules: "pnpm install / npm install"
        case .jsFrameworkBuild, .jsToolCache, .jsBuildOutput: "rebuilt on next build/dev run"
        case .terraform: "terraform init"
        case .terragruntCache: "terragrunt init"
        case .cargoTarget: "cargo build"
        case .pythonVenv: "recreate venv + pip/uv install"
        case .pythonCache: "rebuilt automatically"
        case .composerVendor: "composer install"
        case .cocoaPods: "pod install"
        case .gradle, .dartTool, .xcodeDerivedData: "rebuilt on next build"
        case .gitMetadata: "not regenerable"
        }
    }
}

enum ArtifactRules {
    /// Classifies a child directory using the markers of its parent directory.
    /// Ambiguous names (build, dist, target, vendor, venv…) require a matching marker.
    static func classify(directoryName name: String, parentMarkers markers: ProjectMarkers) -> ArtifactKind? {
        switch name {
        case "node_modules": return .nodeModules
        case ".git": return .gitMetadata
        case ".terraform": return .terraform
        case ".terragrunt-cache": return .terragruntCache
        case ".next", ".nuxt", ".svelte-kit", ".output": return .jsFrameworkBuild
        case ".turbo", ".parcel-cache", ".angular": return .jsToolCache
        case ".venv": return .pythonVenv
        case "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox": return .pythonCache
        case ".gradle": return .gradle
        case ".dart_tool": return .dartTool
        case "DerivedData": return .xcodeDerivedData
        default: break
        }
        switch name {
        case "target" where markers.contains(.cargoToml): return .cargoTarget
        case "venv" where markers.contains(.pythonProject): return .pythonVenv
        case "vendor" where markers.contains(.composerJSON): return .composerVendor
        case "Pods" where markers.contains(.podfile): return .cocoaPods
        case "build" where markers.contains(.gradleBuild): return .gradle
        case "build" where markers.contains(.pubspec): return .dartTool
        case "dist" where markers.contains(.packageJSON),
             "build" where markers.contains(.packageJSON),
             "coverage" where markers.contains(.packageJSON):
            return .jsBuildOutput
        default: return nil
        }
    }
}
