import Foundation

public enum WebHostApps {
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "company.thebrowser.dia"
    ]

    public static let appHostedWebSurfaceBundleIDs: Set<String> = [
        "com.openai.codex",
        "com.todesktop.230313mzl4w4u92"
    ]

    public static let webLikeBundleIDs: Set<String> = browserBundleIDs.union(appHostedWebSurfaceBundleIDs)

    public static func isBrowser(_ bundleID: String) -> Bool {
        browserBundleIDs.contains(bundleID)
    }

    public static func isAppHostedWebSurface(_ bundleID: String) -> Bool {
        appHostedWebSurfaceBundleIDs.contains(bundleID)
    }

    public static func isWebLike(_ bundleID: String) -> Bool {
        webLikeBundleIDs.contains(bundleID)
    }
}
