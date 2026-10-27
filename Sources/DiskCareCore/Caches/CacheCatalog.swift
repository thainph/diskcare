import Foundation

/// Known global developer caches on macOS.
///
/// Locations may overlap (e.g. `~/Library/Caches` and `~/Library/Caches/Homebrew`): the scanner
/// excludes every catalogued location from the others, so each byte is counted once.
/// Docker is handled by `DockerScanner` and deliberately absent here.
public enum CacheCatalog {
    public static func definitions(environment: [String: String] = ProcessInfo.processInfo.environment) -> [CacheDefinition] {
        packageManagers(environment) + browserAutomation + build + ide + system + aiModels
    }

    // MARK: Package managers

    private static func packageManagers(_ environment: [String: String]) -> [CacheDefinition] {
        let goModCache = environment["GOMODCACHE"]
            ?? environment["GOPATH"].flatMap { $0.split(separator: ":").first.map { "\($0)/pkg/mod" } }
            ?? "~/go/pkg/mod"
        let goBuildCache = environment["GOCACHE"] ?? "~/Library/Caches/go-build"
        return [
            CacheDefinition(
                id: "homebrew", title: "Homebrew downloads", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/Homebrew"],
                nativeCommand: NativeCleanCommand(["brew"], ["cleanup", "-s"], timeoutSeconds: 300),
                note: "brew cleanup also removes outdated versions of installed formulae"
            ),
            CacheDefinition(
                id: "npm", title: "npm cache", category: .packageManager, safety: .safe,
                paths: ["~/.npm/_cacache", "~/.npm/_npx"],
                nativeCommand: NativeCleanCommand(["npm"], ["cache", "clean", "--force"])
            ),
            CacheDefinition(
                id: "pnpm-store", title: "pnpm store", category: .packageManager, safety: .safe,
                paths: ["~/Library/pnpm/store", "~/.local/share/pnpm/store", "~/.pnpm-store"],
                nativeCommand: NativeCleanCommand(["pnpm"], ["store", "prune"], timeoutSeconds: 300),
                note: "store files are hard-linked into node_modules; prune only removes unreferenced packages"
            ),
            CacheDefinition(
                id: "pnpm-cache", title: "pnpm metadata cache", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/pnpm"]
            ),
            CacheDefinition(
                id: "yarn", title: "Yarn cache", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/Yarn", "~/.yarn/berry/cache"]
            ),
            CacheDefinition(
                id: "bun", title: "Bun install cache", category: .packageManager, safety: .safe,
                paths: ["~/.bun/install/cache"],
                nativeCommand: NativeCleanCommand(["bun"], ["pm", "cache", "rm"])
            ),
            CacheDefinition(
                id: "corepack", title: "Corepack package managers", category: .packageManager, safety: .safe,
                paths: ["~/.cache/node/corepack"]
            ),
            CacheDefinition(
                id: "nvm-cache", title: "nvm download cache", category: .packageManager, safety: .safe,
                paths: ["~/.nvm/.cache"]
            ),
            CacheDefinition(
                id: "pip", title: "pip cache", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/pip", "~/Library/Caches/pip-tools"],
                nativeCommand: NativeCleanCommand(["pip3", "pip"], ["cache", "purge"])
            ),
            CacheDefinition(
                id: "uv", title: "uv cache", category: .packageManager, safety: .safe,
                paths: ["~/.cache/uv"],
                nativeCommand: NativeCleanCommand(["uv"], ["cache", "clean"], timeoutSeconds: 300)
            ),
            CacheDefinition(
                id: "cargo", title: "Cargo registry & git checkouts", category: .packageManager, safety: .safe,
                paths: ["~/.cargo/registry", "~/.cargo/git"],
                note: "crates are downloaded again on the next build"
            ),
            CacheDefinition(
                id: "go-mod", title: "Go module cache", category: .packageManager, safety: .safe,
                paths: [goModCache],
                nativeCommand: NativeCleanCommand(["go"], ["clean", "-modcache"], timeoutSeconds: 300)
            ),
            CacheDefinition(
                id: "go-build", title: "Go build cache", category: .build, safety: .safe,
                paths: [goBuildCache],
                nativeCommand: NativeCleanCommand(["go"], ["clean", "-cache"])
            ),
            CacheDefinition(
                id: "gradle", title: "Gradle caches", category: .packageManager, safety: .safe,
                paths: ["~/.gradle/caches"]
            ),
            CacheDefinition(
                id: "gradle-wrapper", title: "Gradle wrapper distributions", category: .packageManager, safety: .regenerable,
                paths: ["~/.gradle/wrapper/dists"]
            ),
            CacheDefinition(
                id: "maven", title: "Maven repository", category: .packageManager, safety: .regenerable,
                paths: ["~/.m2/repository"],
                note: "also holds artifacts installed locally with `mvn install`"
            ),
            CacheDefinition(
                id: "cocoapods", title: "CocoaPods cache", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/CocoaPods"],
                nativeCommand: NativeCleanCommand(["pod"], ["cache", "clean", "--all"])
            ),
            CacheDefinition(
                id: "composer", title: "Composer cache", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/composer", "~/.composer/cache", "~/.cache/composer"],
                nativeCommand: NativeCleanCommand(["composer"], ["clear-cache"])
            ),
            CacheDefinition(
                id: "pub", title: "Dart/Flutter pub cache", category: .packageManager, safety: .safe,
                paths: ["~/.pub-cache/hosted", "~/.pub-cache/git"]
            ),
            CacheDefinition(
                id: "swiftpm", title: "SwiftPM cache", category: .packageManager, safety: .safe,
                paths: ["~/Library/Caches/org.swift.swiftpm"]
            ),
        ]
    }

    // MARK: Browser automation

    private static let browserAutomation: [CacheDefinition] = [
        CacheDefinition(
            id: "playwright", title: "Playwright browsers", category: .browserAutomation, safety: .regenerable,
            paths: ["~/Library/Caches/ms-playwright"],
            itemRule: .versions(depth: 1, keep: 1, grouping: .namePrefix),
            note: "projects pinned to an older Playwright re-download their browser on `playwright install`"
        ),
        CacheDefinition(
            id: "playwright-go", title: "Playwright Go drivers", category: .browserAutomation, safety: .regenerable,
            paths: ["~/Library/Caches/ms-playwright-go"],
            itemRule: .versions(depth: 1, keep: 1, grouping: .parent)
        ),
        CacheDefinition(
            id: "puppeteer", title: "Puppeteer browsers", category: .browserAutomation, safety: .regenerable,
            paths: ["~/.cache/puppeteer"],
            itemRule: .versions(depth: 2, keep: 1, grouping: .parent)
        ),
    ]

    // MARK: Build & dev tools

    private static let build: [CacheDefinition] = [
        CacheDefinition(
            id: "xcode-derived-data", title: "Xcode DerivedData", category: .build, safety: .safe,
            paths: ["~/Library/Developer/Xcode/DerivedData"],
            itemRule: .projects(staleDays: 30),
            note: "projects rebuild from scratch on the next build"
        ),
        CacheDefinition(
            id: "xcode-device-support", title: "Xcode device support", category: .build, safety: .regenerable,
            paths: ["~/Library/Developer/Xcode/*DeviceSupport"],
            itemRule: .versions(depth: 1, keep: 2, grouping: .parent),
            note: "symbols are copied again when a device with that OS version is connected"
        ),
        CacheDefinition(
            id: "xcode-archives", title: "Xcode archives", category: .build, safety: .userData,
            paths: ["~/Library/Developer/Xcode/Archives"],
            note: "contain dSYMs needed to symbolicate crash reports of shipped builds"
        ),
        CacheDefinition(
            id: "xcode-cache", title: "Xcode caches", category: .build, safety: .safe,
            paths: ["~/Library/Caches/com.apple.dt.Xcode"]
        ),
        CacheDefinition(
            id: "simulator-caches", title: "Simulator caches", category: .build, safety: .safe,
            paths: ["~/Library/Developer/CoreSimulator/Caches"]
        ),
        CacheDefinition(
            id: "simulator-devices", title: "Simulator devices", category: .build, safety: .regenerable,
            paths: ["~/Library/Developer/CoreSimulator/Devices"],
            nativeCommand: NativeCleanCommand(["xcrun"], ["simctl", "delete", "unavailable"]),
            fallback: .none,
            note: "only devices of runtimes that are no longer installed are deleted"
        ),
        CacheDefinition(
            id: "terraform-plugins", title: "Terraform plugin cache", category: .build, safety: .regenerable,
            paths: ["~/.terraform.d/plugin-cache"],
            note: "existing .terraform dirs may link here; run `terraform init` again"
        ),
        CacheDefinition(
            id: "security-scanners", title: "Security scanner databases", category: .build, safety: .safe,
            paths: ["~/Library/Caches/trivy", "~/Library/Caches/checkov", "~/Library/Caches/tflint"]
        ),
        CacheDefinition(
            id: "prisma", title: "Prisma engines", category: .build, safety: .safe,
            paths: ["~/.cache/prisma", "~/Library/Caches/prisma-nodejs"]
        ),
        CacheDefinition(
            id: "js-tooling", title: "JS tooling caches", category: .build, safety: .safe,
            paths: [
                "~/Library/Caches/next-swc", "~/Library/Caches/swc-native-*", "~/Library/Caches/typescript",
                "~/Library/Caches/node-gyp", "~/Library/Caches/dev.biomejs.biome", "~/Library/Caches/deno",
                "~/.cache/pkg", "~/.cache/giget",
            ]
        ),
        CacheDefinition(
            id: "electron", title: "Electron downloads", category: .build, safety: .safe,
            paths: ["~/Library/Caches/electron", "~/Library/Caches/electron-builder"]
        ),
        CacheDefinition(
            id: "zig", title: "Zig caches", category: .build, safety: .safe,
            paths: ["~/.cache/zig", "~/Library/Caches/cargo-zigbuild"]
        ),
        CacheDefinition(
            id: "flutter-engine", title: "Flutter engine cache", category: .build, safety: .safe,
            paths: ["~/Library/Caches/flutter_engine"]
        ),
    ]

    // MARK: Editors & IDEs

    private static let ide: [CacheDefinition] = [
        CacheDefinition(
            id: "vscode", title: "VS Code caches", category: .ide, safety: .safe,
            paths: [
                "~/Library/Caches/com.microsoft.VSCode", "~/Library/Caches/com.microsoft.VSCode.ShipIt",
                "~/Library/Application Support/Code/Cache", "~/Library/Application Support/Code/CachedData",
                "~/Library/Application Support/Code/CachedExtensionVSIXs", "~/Library/Application Support/Code/Code Cache",
            ],
            note: "quit VS Code first"
        ),
        CacheDefinition(
            id: "cursor", title: "Cursor caches", category: .ide, safety: .safe,
            paths: [
                "~/Library/Caches/cursor-compile-cache", "~/Library/Caches/com.todesktop.*.ShipIt",
                "~/Library/Application Support/Cursor/Cache", "~/Library/Application Support/Cursor/CachedData",
                "~/Library/Application Support/Cursor/CachedExtensionVSIXs", "~/Library/Application Support/Cursor/Code Cache",
            ],
            note: "quit Cursor first"
        ),
        CacheDefinition(
            id: "jetbrains", title: "JetBrains caches", category: .ide, safety: .safe,
            paths: ["~/Library/Caches/JetBrains"],
            note: "IDEs re-index projects on next open"
        ),
        CacheDefinition(
            id: "copilot", title: "GitHub Copilot cache", category: .ide, safety: .safe,
            paths: ["~/.cache/github-copilot", "~/Library/Caches/copilot"]
        ),
    ]

    // MARK: System & apps

    private static let system: [CacheDefinition] = [
        CacheDefinition(
            id: "chrome", title: "Google Chrome cache", category: .system, safety: .safe,
            paths: ["~/Library/Caches/Google"],
            note: "quit Chrome first"
        ),
        CacheDefinition(
            id: "firefox", title: "Firefox cache", category: .system, safety: .safe,
            paths: ["~/Library/Caches/Firefox"]
        ),
        CacheDefinition(
            id: "other-library-caches", title: "Other ~/Library/Caches", category: .system, safety: .safe,
            paths: ["~/Library/Caches"], fallback: .none,
            note: "per-app caches not in the catalog (report only)"
        ),
    ]

    // MARK: AI models

    private static let aiModels: [CacheDefinition] = [
        CacheDefinition(
            id: "ollama", title: "Ollama models", category: .aiModels, safety: .userData,
            paths: ["~/.ollama/models"], note: "remove with `ollama rm <model>`"
        ),
        CacheDefinition(
            id: "huggingface", title: "Hugging Face hub", category: .aiModels, safety: .userData,
            paths: ["~/.cache/huggingface"], note: "remove with `huggingface-cli delete-cache`"
        ),
        CacheDefinition(
            id: "torch", title: "PyTorch hub", category: .aiModels, safety: .userData,
            paths: ["~/.cache/torch"]
        ),
        CacheDefinition(
            id: "lm-studio", title: "LM Studio models", category: .aiModels, safety: .userData,
            paths: ["~/.lmstudio/models", "~/.cache/lm-studio/models"]
        ),
        CacheDefinition(
            id: "whisper", title: "Whisper models", category: .aiModels, safety: .userData,
            paths: ["~/.cache/whisper"]
        ),
    ]
}
