import AppKit
import Foundation

struct InstallationLocationStatus: Equatable {
    let currentPath: String
    let revealPath: String
    let recommendedDirectoryPath: String
    let shouldWarn: Bool

    var currentDirectoryPath: String {
        URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
    }
}

final class InstallationLocationService: ObservableObject {
    @Published private(set) var status: InstallationLocationStatus

    private let bundleURL: URL
    private let executablePath: String
    private let homeDirectory: URL

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        executablePath: String = Bundle.main.executablePath ?? "",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.bundleURL = bundleURL
        self.executablePath = executablePath
        self.homeDirectory = homeDirectory
        self.status = Self.status(
            bundleURL: bundleURL,
            executablePath: executablePath,
            homeDirectory: homeDirectory
        )
    }

    func refresh() {
        status = Self.status(
            bundleURL: bundleURL,
            executablePath: executablePath,
            homeDirectory: homeDirectory
        )
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: status.recommendedDirectoryPath, isDirectory: true))
    }

    func revealCurrentApp() {
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: status.revealPath)
        ])
    }

    static func status(
        bundleURL: URL,
        executablePath: String = "",
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstallationLocationStatus {
        let standardizedBundleURL = resolvedCurrentURL(
            bundleURL: bundleURL,
            executablePath: executablePath
        )
        let recommendedDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let isAppBundle = standardizedBundleURL.pathExtension == "app"
        let shouldWarn = !isAppBundle
            || !isInsideApplicationsDirectory(
                standardizedBundleURL,
                homeDirectory: homeDirectory
            )

        return InstallationLocationStatus(
            currentPath: standardizedBundleURL.path,
            revealPath: standardizedBundleURL.path,
            recommendedDirectoryPath: recommendedDirectory.path,
            shouldWarn: shouldWarn
        )
    }

    private static func resolvedCurrentURL(bundleURL: URL, executablePath: String) -> URL {
        if let appBundle = AppBundleLocator.bundleURL(containingExecutablePath: executablePath) {
            return appBundle
        }

        if let executableURL = AppBundleLocator.standardizedURL(forPath: executablePath) {
            return executableURL
        }

        return bundleURL.standardizedFileURL
    }

    private static func isInsideApplicationsDirectory(
        _ url: URL,
        homeDirectory: URL
    ) -> Bool {
        let appPath = url.standardizedFileURL.path
        let systemApplicationsPath = "/Applications/"
        let homeApplicationsPath = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .standardizedFileURL
            .path + "/"

        return appPath.hasPrefix(systemApplicationsPath)
            || appPath.hasPrefix(homeApplicationsPath)
    }
}
