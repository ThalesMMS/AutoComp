import AppKit
import AutoCompCore
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

final class CompiledBrowserScriptRunner: @unchecked Sendable {
    typealias Executable = () -> BrowserScriptResult
    typealias Compiler = (String) -> Executable?

    private let lock = NSLock()
    private let compiler: Compiler
    private var executables: [String: Executable] = [:]

    init(compiler: @escaping Compiler = CompiledBrowserScriptRunner.compileAppleScript) {
        self.compiler = compiler
    }

    func run(_ source: String) -> BrowserScriptResult {
        lock.withLock {
            let executable: Executable
            if let cached = executables[source] {
                executable = cached
            } else {
                guard let compiled = compiler(source) else {
                    return .failure(code: nil, message: "AppleScript compilation failed")
                }
                executables[source] = compiled
                executable = compiled
            }
            return executable()
        }
    }

    private static func compileAppleScript(_ source: String) -> Executable? {
        guard let script = NSAppleScript(source: source) else { return nil }
        return {
            var error: NSDictionary?
            let descriptor = script.executeAndReturnError(&error)
            if let error {
                return .failure(
                    code: error[NSAppleScript.errorNumber] as? Int,
                    message: error[NSAppleScript.errorMessage] as? String
                )
            }
            return .success(descriptor.stringValue)
        }
    }
}

struct BrowserContextResolverDiagnostics: Equatable {
    let cacheHits: Int
    let scriptExecutions: Int
}

final class BrowserContextResolver: @unchecked Sendable {
    typealias ScriptRunner = (String) -> BrowserScriptResult

    private struct CacheEntry {
        let resolution: BrowserDomainResolution
        let createdAt: Date
    }

    private static let sharedScriptRunner = CompiledBrowserScriptRunner()
    private let lock = NSLock()
    private let scriptRunner: ScriptRunner
    private let cacheTTL: TimeInterval
    private let now: () -> Date
    private var cache: [String: CacheEntry] = [:]
    private var cacheHitCount = 0
    private var scriptExecutionCount = 0

    init(
        scriptRunner: ScriptRunner? = nil,
        cacheTTL: TimeInterval = 0.5,
        now: @escaping () -> Date = { Date() }
    ) {
        self.scriptRunner = scriptRunner ?? Self.sharedScriptRunner.run
        self.cacheTTL = max(0, cacheTTL)
        self.now = now
    }

    convenience init(scriptRunner: @escaping ScriptRunner) {
        self.init(scriptRunner: scriptRunner, cacheTTL: 0.5)
    }

    var diagnostics: BrowserContextResolverDiagnostics {
        lock.withLock {
            BrowserContextResolverDiagnostics(
                cacheHits: cacheHitCount,
                scriptExecutions: scriptExecutionCount
            )
        }
    }

    func activeDomain(for bundleID: String) -> String? {
        activeDomainResolution(for: bundleID).domain
    }

    func activeDomainResolution(for bundleID: String) -> BrowserDomainResolution {
        guard let script = script(for: bundleID) else {
            return BrowserDomainResolution(status: .notBrowser, domain: nil)
        }

        let capturedNow = now()
        if let cached = lock.withLock({ () -> BrowserDomainResolution? in
            guard let entry = cache[bundleID],
                  capturedNow.timeIntervalSince(entry.createdAt) < cacheTTL else {
                cache.removeValue(forKey: bundleID)
                return nil
            }
            cacheHitCount += 1
            return entry.resolution
        }) {
            return cached
        }

        let resolution: BrowserDomainResolution
        switch scriptRunner(script) {
        case .success(let urlString):
            guard let urlString,
                  let host = URL(string: urlString)?.host(percentEncoded: false) else {
                resolution = BrowserDomainResolution(status: .unavailableBrowserScriptFailed, domain: nil)
                break
            }
            resolution = .known(normalizedDomain(host: host, urlString: urlString))
        case .failure(let code, let message):
            if Self.isAppleEventsDenied(code: code, message: message) {
                resolution = BrowserDomainResolution(status: .unavailableAppleEventsDenied, domain: nil)
            } else {
                resolution = BrowserDomainResolution(status: .unavailableBrowserScriptFailed, domain: nil)
            }
        }
        lock.withLock {
            scriptExecutionCount += 1
            cache[bundleID] = CacheEntry(resolution: resolution, createdAt: capturedNow)
        }
        return resolution
    }

    func invalidate(bundleID: String? = nil) {
        lock.withLock {
            if let bundleID {
                cache.removeValue(forKey: bundleID)
            } else {
                cache.removeAll(keepingCapacity: true)
            }
        }
    }

    private func normalizedDomain(host: String, urlString: String) -> String {
        var normalized = host
        if GoogleDocsContext.surface(for: urlString) == .spreadsheet {
            normalized += "/spreadsheets"
        } else if GoogleDocsContext.surface(for: urlString) == .presentation {
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
