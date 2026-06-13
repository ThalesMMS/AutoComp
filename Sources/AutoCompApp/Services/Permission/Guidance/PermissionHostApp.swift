import Foundation

struct PermissionHostApp: Equatable {
    let displayName: String
    let bundleID: String
    let executablePath: String
    let bundleURL: URL?
    let permissionTargetURL: URL?

    static func current(
        bundle: Bundle = .main,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PermissionHostApp {
        PermissionHostApp(
            displayName: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "AutoComp",
            bundleID: bundle.bundleIdentifier ?? "unknown",
            executablePath: bundle.executablePath ?? "unknown",
            bundleURL: bundle.bundleURL,
            searchBaseURLs: searchBaseURLs(
                currentDirectoryPath: currentDirectoryPath,
                environment: environment
            )
        )
    }

    init(
        displayName: String,
        bundleID: String,
        executablePath: String,
        bundleURL: URL?,
        searchBaseURLs: [URL] = []
    ) {
        let resolvedBundleURL = Self.appBundleURL(
            bundleURL: bundleURL,
            executablePath: executablePath,
            searchBaseURLs: searchBaseURLs
        )
        self.displayName = displayName
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.bundleURL = resolvedBundleURL
        self.permissionTargetURL = resolvedBundleURL
    }

    var identityDetail: String {
        if bundleID != "unknown" {
            return bundleID
        }

        return bundleURL?.path ?? "AutoComp.app bundle not found"
    }

    static func permissionTargetURL(
        bundleURL: URL?,
        executablePath: String,
        searchBaseURLs: [URL] = []
    ) -> URL? {
        appBundleURL(
            bundleURL: bundleURL,
            executablePath: executablePath,
            searchBaseURLs: searchBaseURLs
        )
    }

    private static func appBundleURL(
        bundleURL: URL?,
        executablePath: String,
        searchBaseURLs: [URL]
    ) -> URL? {
        AppBundleLocator.bundleURL(from: bundleURL)
            ?? AppBundleLocator.bundleURL(containingExecutablePath: executablePath)
            ?? stagedAppBundleURL(nearExecutablePath: executablePath)
            ?? stagedAppBundleURL(inSearchBaseURLs: searchBaseURLs)
    }

    private static func searchBaseURLs(currentDirectoryPath: String, environment: [String: String]) -> [URL] {
        let paths = [currentDirectoryPath, environment["PWD"], environment["SRCROOT"], environment["PROJECT_DIR"]]
        var seen = Set<String>()
        return paths.compactMap { rawPath -> URL? in
            guard let rawPath,
                  !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }

            let url = URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
            guard seen.insert(url.path).inserted else {
                return nil
            }
            return url
        }
    }

    private static func stagedAppBundleURL(nearExecutablePath executablePath: String) -> URL? {
        guard let executableDirectory = AppBundleLocator.directoryURL(nearPath: executablePath) else {
            return nil
        }

        return stagedAppBundleURL(near: executableDirectory)
    }

    private static func stagedAppBundleURL(inSearchBaseURLs searchBaseURLs: [URL]) -> URL? {
        for searchBaseURL in searchBaseURLs {
            if let bundleURL = stagedAppBundleURL(near: searchBaseURL) {
                return bundleURL
            }
        }

        return nil
    }

    private static func stagedAppBundleURL(near searchBaseURL: URL) -> URL? {
        var candidate = searchBaseURL.standardizedFileURL
        if !candidate.hasDirectoryPath {
            candidate.deleteLastPathComponent()
        }

        while candidate.path != "/" {
            if let existing = existingAppBundleURL(candidate),
               candidate.lastPathComponent == "AutoComp.app" {
                return existing
            }

            let directStagedApp = candidate
                .appendingPathComponent("dist", isDirectory: true)
                .appendingPathComponent("AutoComp.app", isDirectory: true)
            if existingAppBundleURL(directStagedApp) != nil {
                return directStagedApp.standardizedFileURL
            }

            let nestedStagedApp = candidate
                .appendingPathComponent("AutoComp", isDirectory: true)
                .appendingPathComponent("dist", isDirectory: true)
                .appendingPathComponent("AutoComp.app", isDirectory: true)
            if existingAppBundleURL(nestedStagedApp) != nil {
                return nestedStagedApp.standardizedFileURL
            }

            candidate.deleteLastPathComponent()
        }

        return nil
    }

    private static func existingAppBundleURL(_ url: URL) -> URL? {
        guard let standardizedURL = AppBundleLocator.bundleURL(from: url) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        return standardizedURL
    }
}
