/// Files found directly inside a directory that identify what kind of project it is.
public struct ProjectMarkers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let packageJSON = ProjectMarkers(rawValue: 1 << 0)
    public static let cargoToml = ProjectMarkers(rawValue: 1 << 1)
    public static let composerJSON = ProjectMarkers(rawValue: 1 << 2)
    public static let pythonProject = ProjectMarkers(rawValue: 1 << 3)
    public static let podfile = ProjectMarkers(rawValue: 1 << 4)
    public static let gradleBuild = ProjectMarkers(rawValue: 1 << 5)
    public static let pubspec = ProjectMarkers(rawValue: 1 << 6)
    public static let goMod = ProjectMarkers(rawValue: 1 << 7)
    public static let terraform = ProjectMarkers(rawValue: 1 << 8)
    /// `.git` is a directory: repository root.
    public static let gitDirectory = ProjectMarkers(rawValue: 1 << 9)
    /// `.git` is a file: linked worktree (or submodule).
    public static let gitFile = ProjectMarkers(rawValue: 1 << 10)

    public static let anyGit: ProjectMarkers = [.gitDirectory, .gitFile]

    private static let fileNames: [(bytes: [UInt8], marker: ProjectMarkers)] = ([
        ("package.json", .packageJSON),
        ("Cargo.toml", .cargoToml),
        ("composer.json", .composerJSON),
        ("pyproject.toml", .pythonProject),
        ("requirements.txt", .pythonProject),
        ("setup.py", .pythonProject),
        ("Podfile", .podfile),
        ("build.gradle", .gradleBuild),
        ("build.gradle.kts", .gradleBuild),
        ("pubspec.yaml", .pubspec),
        ("go.mod", .goMod),
        (".git", .gitFile),
    ] as [(String, ProjectMarkers)]).map { (Array($0.0.utf8), $0.1) }

    private static let terraformSuffix = Array(".tf".utf8)

    /// Matches a regular file name (raw UTF-8, no NUL) without allocating a String.
    static func match(fileName name: UnsafeBufferPointer<UInt8>) -> ProjectMarkers {
        for candidate in fileNames where candidate.bytes.count == name.count {
            if candidate.bytes.elementsEqual(name) { return candidate.marker }
        }
        if name.count > terraformSuffix.count,
           name[(name.count - 3)...].elementsEqual(terraformSuffix) {
            return .terraform
        }
        return []
    }
}
