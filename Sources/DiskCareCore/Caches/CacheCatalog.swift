import Foundation

/// Known global developer caches on macOS.
///
/// Locations may overlap (e.g. `~/Library/Caches` and `~/Library/Caches/Homebrew`): the scanner
/// excludes every catalogued location from the others, so each byte is counted once.
/// Docker is handled by `DockerScanner` and deliberately absent here.
public enum CacheCatalog {
    /// Static locations plus the ones found in tool configuration (Cargo build dirs). `scanRoots`
    /// lets project-level `.cargo/config.toml` files be found as well.
    public static func definitions(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        scanRoots: [String] = []
    ) -> [CacheDefinition] {
        packageManagers(environment, home: home) + cargoBuild(home: home, environment: environment, scanRoots: scanRoots)
            + browserAutomation + build(home: home, environment: environment) + ide + system + aiModels
            + untrustedConfigured(home: home, environment: environment)
    }

    // MARK: Locations from configuration

    /// What a configured cache directory must look like before DiskCare empties it.
    enum CacheLayout {
        case pnpmStore, sccache, terraformPluginCache

        func matches(_ path: String) -> Bool {
            let children = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
            return children.allSatisfy { name in
                if name == ".DS_Store" || Cleaner.isStagingName(name) { return true }
                let isDirectory = CachePaths.isRealDirectory(path + "/" + name)
                switch self {
                case .pnpmStore:  // v3, v10…
                    return isDirectory && name.first == "v" && name.dropFirst().allSatisfy(\.isNumber) && name.count > 1
                case .sccache:  // CACHEDIR.TAG + one directory per first hex digit of the hash
                    return name == "CACHEDIR.TAG" || (isDirectory && name.count == 1 && name.allSatisfy(\.isHexDigit))
                case .terraformPluginCache:  // registry host names
                    return isDirectory && name.contains(".")
                }
            }
        }
    }

    /// Why a directory named in configuration (rc files, tool config) must not be cleaned; nil when it
    /// is a real directory outside protected places, laid out like the tool's own cache.
    static func configuredProblem(_ path: String, home: String, environment: [String: String], layout: CacheLayout) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if let problem = DeletionGuard(roots: [], home: home, environment: environment).checkUntrusted(ScanOptions.normalize(path)) {
            return problem
        }
        return layout.matches(path) ? nil : "does not look like its cache (unexpected contents)"
    }

    static func trusted(_ paths: [String], home: String, environment: [String: String], layout: CacheLayout) -> [String] {
        paths.filter { configuredProblem($0, home: home, environment: environment, layout: layout) == nil }
    }

    /// Configured cache directories that failed the checks: still measured, never cleaned.
    static func untrustedConfigured(home: String, environment: [String: String]) -> [CacheDefinition] {
        let candidates: [(id: String, title: String, paths: [String], layout: CacheLayout, source: String)] = [
            ("pnpm-store-configured", "pnpm store (configured)", pnpmStoreDirectories(environment: environment, home: home), .pnpmStore, "store-dir"),
            ("sccache-configured", "sccache (configured)", [CargoBuildCacheCheck.sccacheDirectory(home: home, environment: environment)], .sccache, "SCCACHE_DIR"),
            ("terraform-plugins-configured", "Terraform plugin cache (configured)",
             TerraformPluginCacheCheck.pluginCacheDirectory(home: home, environment: environment).map { [$0] } ?? [], .terraformPluginCache, "plugin_cache_dir"),
        ]
        return candidates.compactMap { candidate in
            let refused = candidate.paths.compactMap { path in
                configuredProblem(path, home: home, environment: environment, layout: candidate.layout).map { (path, $0) }
            }
            guard let first = refused.first else { return nil }
            return CacheDefinition(
                id: candidate.id, title: candidate.title, category: .build, safety: .userData, paths: refused.map(\.0),
                fallback: .none, note: "report only: \(first.1) (from \(candidate.source))"
            )
        }
    }

    /// `store-dir` from pnpm's global rc files or `npm_config_store_dir`; pnpm puts the store in a
    /// versioned subdirectory (`v10`) of it, so the whole directory is measured.
    static func pnpmStoreDirectories(environment: [String: String], home: String) -> [String] {
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        var values = [environment["npm_config_store_dir"]].compactMap { $0 }
        for file in [home + "/Library/Preferences/pnpm/rc", xdg + "/pnpm/rc", home + "/.npmrc"] {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0] == "store-dir" { values.append(parts[1]) }
            }
        }
        return values.map { $0.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home) }
            .filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
    }

    // MARK: Configured build locations

    /// Cargo build dirs from `build.target-dir` / `build.build-dir` / `CARGO_TARGET_DIR`. One that fails
    /// the safety gate is still measured, but report-only, with the reason in its note.
    static func cargoBuild(home: String, environment: [String: String], scanRoots: [String]) -> [CacheDefinition] {
        var environment = environment
        environment["CARGO_HOME"] = CargoBuildLocator.cargoHome(home: home, environment: environment)
        let guardrail = DeletionGuard(roots: scanRoots, home: home, environment: environment)
        var used = Set<String>()
        return CargoBuildLocator.locate(home: home, environment: environment, scanRoots: scanRoots).compactMap { location in
            guard FileManager.default.fileExists(atPath: location.path) else { return nil }
            let problem = location.buildDirDepth == 0
                ? CargoBuildDirectory.gateProblem(location.path, guardrail: guardrail)
                : guardrail.checkUntrusted(location.path)
            var id = location.buildDirDepth == 0 ? "cargo-target-shared" : "cargo-build-dir"
            if !used.insert(id).inserted {
                var suffix = 2
                while !used.insert("\(id)-\(suffix)").inserted { suffix += 1 }
                id += "-\(suffix)"
            }
            return CacheDefinition(
                id: id, title: (location.buildDirDepth == 0 ? "Cargo shared target dir" : "Cargo build dirs") + " (\(location.path.abbreviatingHome))",
                category: .build, safety: problem == nil ? .regenerable : .userData,
                paths: [location.path], fallback: .none,
                itemRule: problem == nil ? .cargoProfiles(buildDirDepth: location.buildDirDepth) : nil,
                note: problem.map { "report only: \($0) (from \(location.source))" }
                    ?? "from \(location.source); shared by every project, so it never goes stale: clean incremental/ regularly"
            )
        }
    }

    // MARK: Package managers

    private static func packageManagers(_ environment: [String: String], home: String) -> [CacheDefinition] {
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
                paths: trusted(pnpmStoreDirectories(environment: environment, home: home), home: home, environment: environment, layout: .pnpmStore)
                    + ["~/Library/pnpm/store", "~/.local/share/pnpm/store", "~/.pnpm-store"],
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

    private static func build(home: String, environment: [String: String]) -> [CacheDefinition] { [
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
            paths: trusted(TerraformPluginCacheCheck.pluginCacheDirectory(home: home, environment: environment).map { [$0] } ?? [],
                           home: home, environment: environment, layout: .terraformPluginCache)
                + ["~/.terraform.d/plugin-cache"],
            itemRule: .terraformProviders,
            note: "existing .terraform dirs may link here; run `terraform init` again"
        ),
        CacheDefinition(
            id: "sccache", title: "sccache compiler cache", category: .build, safety: .safe,
            paths: trusted([CargoBuildCacheCheck.sccacheDirectory(home: home, environment: environment)],
                           home: home, environment: environment, layout: .sccache),
            note: "size-capped (SCCACHE_CACHE_SIZE); refilled by the next builds"
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
    ] }

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
        appData,
    ]

    /// Everything in Application Support no other entry claims, broken down by app (report only).
    /// Contacts, iOS backups and Apple's own folders are never read: macOS guards them.
    static var appData: CacheDefinition {
        var definition = CacheDefinition(
            id: "app-data", title: "App data (Application Support)", category: .system, safety: .userData,
            paths: ["~/Library/Application Support"], fallback: .none,
            itemRule: .largeChildren(minimumBytes: 2_000_000_000),
            note: "apps' own data (chats, models, projects); report only"
        )
        definition.excludedChildren = ["AddressBook", "MobileSync", "CallHistoryDB", "CallHistoryTransactions",
                                       "Knowledge", "com.apple.*", "FileProvider", "CloudDocs"]
        return definition
    }

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
