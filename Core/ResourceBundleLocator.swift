import Foundation

/// Finds a SwiftPM resource bundle at runtime without ever trapping.
///
/// The `Bundle.module` accessor that `swift build` generates looks in exactly
/// two places: beside the executable (`Bundle.main.bundleURL`) and at the
/// absolute path of the build directory on the machine that produced the
/// binary. Inside a packaged .app the bundle lives in `Contents/Resources`,
/// so the first misses, and the second only works on the build machine while
/// that tree still exists. When both fail the accessor calls `fatalError`.
/// Callers should resolve bundles through this type instead and treat nil as
/// "resource unavailable".
public enum ResourceBundleLocator {
    /// Directories searched, in order, for `<name>.bundle`: the .app's
    /// `Contents/Resources`, then the directory holding the executable (a
    /// `swift build` tree, where the bundle sits next to the binary).
    public static func defaultSearchDirectories(main: Bundle = .main) -> [URL] {
        var directories: [URL] = []
        if let resources = main.resourceURL { directories.append(resources) }
        if let executable = main.executableURL {
            directories.append(executable.deletingLastPathComponent())
        }
        directories.append(main.bundleURL)
        return directories
    }

    /// The first `<name>.bundle` directory found under `directories`.
    public static func url(named name: String, in directories: [URL]) -> URL? {
        let fileManager = FileManager.default
        var visited = Set<String>()
        for directory in directories {
            let candidate = directory
                .appendingPathComponent("\(name).bundle", isDirectory: true)
                .standardizedFileURL
            guard visited.insert(candidate.path).inserted else { continue }
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// The resource bundle called `name`, or nil when it is not shipped.
    public static func bundle(named name: String, main: Bundle = .main) -> Bundle? {
        url(named: name, in: defaultSearchDirectories(main: main))
            .flatMap { Bundle(url: $0) }
    }
}
