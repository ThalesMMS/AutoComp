import Foundation

enum AppBundleLocator {
    private static let unknownExecutablePath = "unknown"

    static func bundleURL(from url: URL?) -> URL? {
        guard let standardizedURL = url?.standardizedFileURL,
              standardizedURL.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }

        return standardizedURL
    }

    static func bundleURL(containingExecutablePath executablePath: String) -> URL? {
        guard var candidate = standardizedURL(forPath: executablePath) else {
            return nil
        }

        while candidate.path != "/" {
            if candidate.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }

        return nil
    }

    static func directoryURL(nearPath path: String) -> URL? {
        guard var candidate = standardizedURL(forPath: path) else {
            return nil
        }

        if !candidate.hasDirectoryPath {
            candidate.deleteLastPathComponent()
        }

        return candidate
    }

    static func standardizedURL(forPath path: String) -> URL? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty,
              trimmedPath != unknownExecutablePath else {
            return nil
        }

        return URL(fileURLWithPath: trimmedPath).standardizedFileURL
    }
}
