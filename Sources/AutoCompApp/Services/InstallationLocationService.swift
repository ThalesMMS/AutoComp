import AppKit
import Foundation

struct InstallationLocationStatus: Equatable {
    let currentPath: String
    let recommendedDirectoryPath: String
    let shouldWarn: Bool

    var currentDirectoryPath: String {
        URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
    }
}

final class InstallationLocationService: ObservableObject {
    @Published private(set) var status: InstallationLocationStatus

    private let bundleURL: URL
    private let homeDirectory: URL

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.bundleURL = bundleURL
        self.homeDirectory = homeDirectory
        self.status = Self.status(bundleURL: bundleURL, homeDirectory: homeDirectory)
    }

    func refresh() {
        status = Self.status(bundleURL: bundleURL, homeDirectory: homeDirectory)
    }

    func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: status.recommendedDirectoryPath, isDirectory: true))
    }

    func revealCurrentApp() {
        NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
    }

    static func status(
        bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> InstallationLocationStatus {
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let recommendedDirectory = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let isAppBundle = standardizedBundleURL.pathExtension == "app"
        let shouldWarn = isAppBundle
            && !isInsideApplicationsDirectory(
                standardizedBundleURL,
                homeDirectory: homeDirectory
            )

        return InstallationLocationStatus(
            currentPath: standardizedBundleURL.path,
            recommendedDirectoryPath: recommendedDirectory.path,
            shouldWarn: shouldWarn
        )
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
