import AppKit
import Foundation

enum BrowserDomainResolutionStatus: String, Codable, Equatable, Sendable {
    case known = "known"
    case unavailableAppleEventsDenied = "unavailable-appleevents-denied"
    case unavailableBrowserScriptFailed = "unavailable-browser-script-failed"
    case notBrowser = "not-browser"
}

struct BrowserDomainResolution: Equatable, Sendable {
    let status: BrowserDomainResolutionStatus
    let domain: String?

    var diagnosticValue: String {
        switch status {
        case .known:
            return domain ?? BrowserDomainResolutionStatus.unavailableBrowserScriptFailed.rawValue
        case .unavailableAppleEventsDenied, .unavailableBrowserScriptFailed, .notBrowser:
            return status.rawValue
        }
    }

    static func known(_ domain: String) -> BrowserDomainResolution {
        BrowserDomainResolution(status: .known, domain: domain)
    }

    static func inferred(domain: String?) -> BrowserDomainResolution {
        if let domain {
            return .known(domain)
        }
        return BrowserDomainResolution(status: .notBrowser, domain: nil)
    }

    func resolvingEffectiveDomain(_ domain: String?) -> BrowserDomainResolution {
        guard let domain else {
            return self
        }
        return .known(domain)
    }
}

enum BrowserScriptResult: Equatable {
    case success(String?)
    case failure(code: Int?, message: String?)
}

struct BrowserContextResolver {
    typealias ScriptRunner = (String) -> BrowserScriptResult

    private let scriptRunner: ScriptRunner

    init(scriptRunner: @escaping ScriptRunner = BrowserContextResolver.runAppleScript) {
        self.scriptRunner = scriptRunner
    }

    func activeDomain(for bundleID: String) -> String? {
        activeDomainResolution(for: bundleID).domain
    }

    func activeDomainResolution(for bundleID: String) -> BrowserDomainResolution {
        guard let script = script(for: bundleID) else {
            return BrowserDomainResolution(status: .notBrowser, domain: nil)
        }

        switch scriptRunner(script) {
        case .success(let urlString):
            guard let urlString,
                  let host = URL(string: urlString)?.host(percentEncoded: false) else {
                return BrowserDomainResolution(status: .unavailableBrowserScriptFailed, domain: nil)
            }
            return .known(normalizedDomain(host: host, urlString: urlString))
        case .failure(let code, let message):
            if Self.isAppleEventsDenied(code: code, message: message) {
                return BrowserDomainResolution(status: .unavailableAppleEventsDenied, domain: nil)
            }
            return BrowserDomainResolution(status: .unavailableBrowserScriptFailed, domain: nil)
        }
    }

    private func normalizedDomain(host: String, urlString: String) -> String {
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

    private static func runAppleScript(_ script: String) -> BrowserScriptResult {
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: script)?.executeAndReturnError(&error) else {
            return .failure(
                code: error?[NSAppleScript.errorNumber] as? Int,
                message: error?[NSAppleScript.errorMessage] as? String
            )
        }
        return .success(descriptor.stringValue)
    }

    private static func isAppleEventsDenied(code: Int?, message: String?) -> Bool {
        if code == -1743 {
            return true
        }
        let normalizedMessage = message?.lowercased() ?? ""
        return normalizedMessage.contains("not authorized")
            || normalizedMessage.contains("not authorised")
            || normalizedMessage.contains("not permitted")
    }
}
