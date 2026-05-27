import AppKit
import Foundation

struct InstalledApplication: Identifiable {
    var id: String { bundleID }

    let displayName: String
    let bundleID: String
    let url: URL
    let icon: NSImage
}

struct InstalledApplicationScanner {
    var roots: [URL] = Self.defaultRoots
    var fileManager: FileManager = .default
    var iconProvider: (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }

    init(
        roots: [URL] = Self.defaultRoots,
        fileManager: FileManager = .default,
        iconProvider: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.roots = roots
        self.fileManager = fileManager
        self.iconProvider = iconProvider
    }

    func scan() -> [InstalledApplication] {
        var appsByBundleID: [String: InstalledApplication] = [:]

        for root in roots {
            scan(root: root, into: &appsByBundleID)
        }

        return appsByBundleID.values.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.bundleID.localizedCaseInsensitiveCompare($1.bundleID) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func scan(root: URL, into appsByBundleID: inout [String: InstalledApplication]) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for case let url as URL in enumerator {
            guard url.pathExtension == "app" else {
                continue
            }

            defer {
                enumerator.skipDescendants()
            }

            guard let app = application(at: url),
                  appsByBundleID[app.bundleID] == nil else {
                continue
            }
            appsByBundleID[app.bundleID] = app
        }
    }

    private func application(at url: URL) -> InstalledApplication? {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let displayName = [
            plist["CFBundleDisplayName"] as? String,
            plist["CFBundleName"] as? String,
            url.deletingPathExtension().lastPathComponent
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? bundleID

        return InstalledApplication(
            displayName: displayName,
            bundleID: bundleID,
            url: url,
            icon: iconProvider(url.path)
        )
    }
}

extension InstalledApplicationScanner {
    static var defaultRoots: [URL] {
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications/Utilities", isDirectory: true),
            homeApplications
        ]
    }
}

enum InstalledApplicationFilter {
    static func filter(_ apps: [InstalledApplication], matching searchText: String) -> [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return apps
        }

        return apps.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }
}
