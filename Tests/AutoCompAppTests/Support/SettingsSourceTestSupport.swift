import Foundation

func settingsSourceContents(packageRoot: URL) throws -> String {
    let settingsRoot = packageRoot.appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift")
    let settingsDirectory = packageRoot.appendingPathComponent("Sources/AutoCompApp/Views/Settings")
    var sourceURLs = [settingsRoot]

    if let enumerator = FileManager.default.enumerator(
        at: settingsDirectory,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) {
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            sourceURLs.append(url)
        }
    }

    return try sourceURLs
        .sorted { $0.path < $1.path }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")
}
