import CryptoKit
import Foundation

public enum TelemetryPermissionKind: String, CaseIterable, Codable, Sendable {
    case accessibility
    case inputMonitoring
    case screenRecording
}

public enum TelemetryPermissionStatus: String, Codable, Sendable {
    case granted
    case denied
    case unknown
}

public struct TelemetryTechnicalError: Codable, Equatable, Sendable {
    public var category: String
    public var code: String?

    public init(category: String, code: String? = nil) {
        self.category = TelemetryRedactor.sanitizedToken(category, fallback: "technical-error")
        self.code = code.map { TelemetryRedactor.sanitizedToken($0, fallback: "unknown") }
    }
}

public struct TelemetryEventInput: Sendable {
    public var name: String
    public var appVersion: String
    public var buildNumber: String
    public var backendKind: CompletionEngineKind?
    public var technicalError: TelemetryTechnicalError?
    public var permissionStatuses: [TelemetryPermissionKind: TelemetryPermissionStatus]
    public var bundleID: String?

    public var prompt: String?
    public var textBeforeCursor: String?
    public var textAfterCursor: String?
    public var clipboard: String?
    public var ocrText: String?
    public var screenshotDescription: String?
    public var suggestion: String?
    public var url: String?
    public var domain: String?

    public init(
        name: String,
        appVersion: String,
        buildNumber: String,
        backendKind: CompletionEngineKind? = nil,
        technicalError: TelemetryTechnicalError? = nil,
        permissionStatuses: [TelemetryPermissionKind: TelemetryPermissionStatus] = [:],
        bundleID: String? = nil,
        prompt: String? = nil,
        textBeforeCursor: String? = nil,
        textAfterCursor: String? = nil,
        clipboard: String? = nil,
        ocrText: String? = nil,
        screenshotDescription: String? = nil,
        suggestion: String? = nil,
        url: String? = nil,
        domain: String? = nil
    ) {
        self.name = name
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.backendKind = backendKind
        self.technicalError = technicalError
        self.permissionStatuses = permissionStatuses
        self.bundleID = bundleID
        self.prompt = prompt
        self.textBeforeCursor = textBeforeCursor
        self.textAfterCursor = textAfterCursor
        self.clipboard = clipboard
        self.ocrText = ocrText
        self.screenshotDescription = screenshotDescription
        self.suggestion = suggestion
        self.url = url
        self.domain = domain
    }
}

public struct TelemetryEvent: Codable, Equatable, Sendable {
    public var name: String
    public var appVersion: String
    public var buildNumber: String
    public var backendKind: CompletionEngineKind?
    public var technicalError: TelemetryTechnicalError?
    public var permissionStatuses: [String: String]
    public var bundleIDHash: String?

    public init(
        name: String,
        appVersion: String,
        buildNumber: String,
        backendKind: CompletionEngineKind? = nil,
        technicalError: TelemetryTechnicalError? = nil,
        permissionStatuses: [String: String] = [:],
        bundleIDHash: String? = nil
    ) {
        self.name = name
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.backendKind = backendKind
        self.technicalError = technicalError
        self.permissionStatuses = permissionStatuses
        self.bundleIDHash = bundleIDHash
    }
}

public enum TelemetryRedactor {
    public static func sanitizedEvent(from input: TelemetryEventInput) -> TelemetryEvent {
        TelemetryEvent(
            name: sanitizedToken(input.name, fallback: "event"),
            appVersion: sanitizedToken(input.appVersion, fallback: "unknown"),
            buildNumber: sanitizedToken(input.buildNumber, fallback: "unknown"),
            backendKind: input.backendKind,
            technicalError: input.technicalError,
            permissionStatuses: Dictionary(
                uniqueKeysWithValues: input.permissionStatuses.map { kind, status in
                    (kind.rawValue, status.rawValue)
                }
            ),
            bundleIDHash: input.bundleID.map(hashedIdentifier)
        )
    }

    public static func hashedIdentifier(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func sanitizedToken(_ value: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_."))
        return String((collapsed.isEmpty ? fallback : collapsed).prefix(80))
    }
}

public protocol TelemetryEventSink: Sendable {
    func send(_ event: TelemetryEvent)
    func deleteAll()
}

public struct NoopTelemetryEventSink: TelemetryEventSink {
    public init() {}

    public func send(_ event: TelemetryEvent) {}

    public func deleteAll() {}
}

public protocol TelemetryClient: Sendable {
    func setEnabled(_ isEnabled: Bool)
    func capture(_ input: TelemetryEventInput)
    func deleteAll()
}

public struct DisabledTelemetryClient: TelemetryClient {
    public init() {}

    public func setEnabled(_ isEnabled: Bool) {}

    public func capture(_ input: TelemetryEventInput) {}

    public func deleteAll() {}
}

public final class RedactingTelemetryClient: TelemetryClient, @unchecked Sendable {
    private let sink: any TelemetryEventSink
    private let lock = NSLock()
    private var isEnabled: Bool

    public init(
        enabled: Bool = false,
        sink: any TelemetryEventSink = NoopTelemetryEventSink()
    ) {
        self.isEnabled = enabled
        self.sink = sink
    }

    public func setEnabled(_ isEnabled: Bool) {
        lock.lock()
        let wasEnabled = self.isEnabled
        self.isEnabled = isEnabled
        lock.unlock()

        if wasEnabled && !isEnabled {
            sink.deleteAll()
        }
    }

    public func capture(_ input: TelemetryEventInput) {
        lock.lock()
        let enabled = isEnabled
        lock.unlock()

        guard enabled else {
            return
        }

        sink.send(TelemetryRedactor.sanitizedEvent(from: input))
    }

    public func deleteAll() {
        setEnabled(false)
        sink.deleteAll()
    }
}
