import AppKit
import CoreGraphics
import Foundation

struct SystemSettingsWindow: Equatable {
    let ownerPID: pid_t
    let title: String
    let frame: CGRect
}

protocol SystemSettingsWindowLocating {
    func locateSystemSettingsWindow() -> SystemSettingsWindow?
}

struct SystemSettingsWindowLocator: SystemSettingsWindowLocating {
    var runningApplications: () -> [NSRunningApplication] = {
        NSWorkspace.shared.runningApplications
    }
    var windowInfo: () -> [[String: Any]] = {
        guard let rawWindows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }
        return rawWindows
    }
    var mainScreenFrame: () -> CGRect = {
        NSScreen.screens.first?.frame
            ?? NSScreen.main?.frame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func locateSystemSettingsWindow() -> SystemSettingsWindow? {
        let settingsPIDs = Set(runningApplications().compactMap { app -> pid_t? in
            guard isSystemSettings(app) else { return nil }
            return app.processIdentifier
        })
        guard !settingsPIDs.isEmpty else {
            return nil
        }

        for window in windowInfo() {
            guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  settingsPIDs.contains(ownerPID),
                  let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let cgFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else {
                continue
            }

            let frame = Self.appKitFrame(cgWindowBounds: cgFrame, mainScreenFrame: mainScreenFrame())
            guard frame.width > 200,
                  frame.height > 160 else {
                continue
            }

            return SystemSettingsWindow(
                ownerPID: ownerPID,
                title: window[kCGWindowName as String] as? String ?? "System Settings",
                frame: frame
            )
        }

        return nil
    }

    static func appKitFrame(cgWindowBounds bounds: CGRect, mainScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX,
            y: mainScreenFrame.maxY - bounds.maxY,
            width: bounds.width,
            height: bounds.height
        )
    }

    private func isSystemSettings(_ app: NSRunningApplication) -> Bool {
        switch app.bundleIdentifier {
        case "com.apple.systempreferences", "com.apple.SystemPreferences":
            return true
        default:
            return app.localizedName == "System Settings" || app.localizedName == "System Preferences"
        }
    }
}
