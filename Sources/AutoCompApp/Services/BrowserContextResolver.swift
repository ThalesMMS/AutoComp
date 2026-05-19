import AppKit
import Foundation

struct BrowserContextResolver {
    func activeDomain(for bundleID: String) -> String? {
        guard let script = script(for: bundleID) else {
            return nil
        }

        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error),
              let urlString = descriptor.stringValue,
              let host = URL(string: urlString)?.host(percentEncoded: false) else {
            return nil
        }

        var normalized = host
        if urlString.contains("docs.google.com/spreadsheets") {
            normalized += "/spreadsheets"
        } else if urlString.contains("docs.google.com/presentation") {
            normalized += "/presentation"
        }

        return normalized
    }

    private func script(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return #"tell application "Safari" to get URL of front document"#
        case "com.google.Chrome":
            return #"tell application "Google Chrome" to get URL of active tab of front window"#
        case "com.brave.Browser":
            return #"tell application "Brave Browser" to get URL of active tab of front window"#
        case "com.microsoft.edgemac":
            return #"tell application "Microsoft Edge" to get URL of active tab of front window"#
        default:
            return nil
        }
    }
}
