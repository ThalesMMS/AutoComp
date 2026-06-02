import Foundation

public enum AutoCompUserDirectories {
    public static var applicationSupportDirectory: URL {
        applicationSupportDirectory(homeDirectory: defaultHomeDirectory())
    }

    public static var appSupportDirectory: URL {
        appSupportDirectory(homeDirectory: defaultHomeDirectory())
    }

    public static func applicationSupportDirectory(homeDirectory: URL) -> URL {
        homeDirectory.standardizedFileURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
    }

    public static func appSupportDirectory(homeDirectory: URL) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("AutoComp", isDirectory: true)
    }

    private static func defaultHomeDirectory() -> URL {
        let homePath = NSHomeDirectory()
        if !homePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: homePath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
