import CoreGraphics
import Foundation

public enum TextCaptureSource: String, Codable, CaseIterable, Sendable {
    case accessibility
    case screenOCR
    case clipboard
    case keystrokeBufferLowTrust
}

public struct StableFieldIdentity: Codable, Equatable, Sendable {
    public let bundleID: String
    public let processID: Int32
    public let domain: String?
    public let role: String?
    public let subrole: String?
    public let roundedFocusedElementFrame: CGRect?
    public let focusChangeSequence: UInt64?

    public init(
        bundleID: String,
        processID: Int32,
        domain: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        roundedFocusedElementFrame: CGRect? = nil,
        focusChangeSequence: UInt64? = nil
    ) {
        self.bundleID = bundleID
        self.processID = processID
        self.domain = Self.normalized(domain)
        self.role = Self.normalized(role)
        self.subrole = Self.normalized(subrole)
        self.roundedFocusedElementFrame = Self.roundedFrame(roundedFocusedElementFrame)
        self.focusChangeSequence = focusChangeSequence
    }

    public init(
        app: AppIdentity,
        domain: String? = nil,
        role: String? = nil,
        subrole: String? = nil,
        focusedElementFrame: CGRect? = nil,
        focusChangeSequence: UInt64? = nil
    ) {
        self.init(
            bundleID: app.bundleID,
            processID: app.processID,
            domain: domain,
            role: role,
            subrole: subrole,
            roundedFocusedElementFrame: focusedElementFrame,
            focusChangeSequence: focusChangeSequence
        )
    }

    public func withFocusChangeSequence(_ sequence: UInt64) -> StableFieldIdentity {
        StableFieldIdentity(
            bundleID: bundleID,
            processID: processID,
            domain: domain,
            role: role,
            subrole: subrole,
            roundedFocusedElementFrame: roundedFocusedElementFrame,
            focusChangeSequence: sequence
        )
    }

    public func matchesStableTarget(_ other: StableFieldIdentity) -> Bool {
        guard let roundedFocusedElementFrame,
              let otherRoundedFocusedElementFrame = other.roundedFocusedElementFrame else {
            return false
        }

        return bundleID == other.bundleID
            && processID == other.processID
            && domain == other.domain
            && role == other.role
            && subrole == other.subrole
            && roundedFocusedElementFrame == otherRoundedFocusedElementFrame
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func roundedFrame(_ frame: CGRect?) -> CGRect? {
        guard let frame,
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.size.width.isFinite,
              frame.size.height.isFinite else {
            return nil
        }

        return CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.size.width.rounded(),
            height: frame.size.height.rounded()
        )
    }
}

public struct TextContext: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let app: AppIdentity
    public let domain: String?
    public let focusedElementID: String
    public let stableFieldIdentity: StableFieldIdentity?
    public let textBeforeCursor: String
    public let textAfterCursor: String?
    public let selectedText: String?
    public let fullTextWindow: String?
    public let selectedRange: NSRange?
    public let caretRect: CGRect?
    public let focusedElementRect: CGRect?
    public let previousGlyphRect: CGRect?
    public let nextGlyphRect: CGRect?
    public let lineReferenceRect: CGRect?
    public let caretGeometryQuality: CaretGeometryQuality
    public let observedCharacterWidth: CGFloat?
    public let languageHint: String?
    public let captureSources: Set<TextCaptureSource>
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        app: AppIdentity,
        domain: String? = nil,
        focusedElementID: String,
        stableFieldIdentity: StableFieldIdentity? = nil,
        textBeforeCursor: String,
        textAfterCursor: String? = nil,
        selectedText: String? = nil,
        fullTextWindow: String? = nil,
        selectedRange: NSRange? = nil,
        caretRect: CGRect? = nil,
        focusedElementRect: CGRect? = nil,
        previousGlyphRect: CGRect? = nil,
        nextGlyphRect: CGRect? = nil,
        lineReferenceRect: CGRect? = nil,
        caretGeometryQuality: CaretGeometryQuality = .unavailable,
        observedCharacterWidth: CGFloat? = nil,
        languageHint: String? = nil,
        captureSources: Set<TextCaptureSource> = [.accessibility],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.app = app
        self.domain = domain
        self.focusedElementID = focusedElementID
        self.stableFieldIdentity = stableFieldIdentity
        self.textBeforeCursor = textBeforeCursor
        self.textAfterCursor = textAfterCursor
        self.selectedText = selectedText
        self.fullTextWindow = fullTextWindow
        self.selectedRange = selectedRange
        self.caretRect = caretRect
        self.focusedElementRect = focusedElementRect
        self.previousGlyphRect = previousGlyphRect
        self.nextGlyphRect = nextGlyphRect
        self.lineReferenceRect = lineReferenceRect
        self.caretGeometryQuality = caretGeometryQuality
        self.observedCharacterWidth = observedCharacterWidth
        self.languageHint = languageHint
        self.captureSources = captureSources
        self.createdAt = createdAt
    }
}
