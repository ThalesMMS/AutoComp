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

    /// Best-effort comparison for determining whether two focus snapshots refer to the
    /// same logical input field.
    ///
    /// This is intentionally tolerant of missing fields (e.g. some apps do not expose
    /// reliable frames/roles). We require bundleID + pid to match, then:
    /// - If both sides have a focusChangeSequence, it must match (most reliable signal).
    /// - Otherwise, we compare any available optional fields; if a field is present on
    ///   both sides it must match, but if either side lacks it we ignore it.
    public func matchesStableTarget(_ other: StableFieldIdentity) -> Bool {
        guard bundleID == other.bundleID, processID == other.processID else {
            return false
        }

        if isSameGoogleDocsVolatileLineTarget(as: other) {
            return true
        }

        if let focusChangeSequence, let otherFocusChangeSequence = other.focusChangeSequence {
            return focusChangeSequence == otherFocusChangeSequence
        }

        if let domain, let otherDomain = other.domain, domain != otherDomain {
            return false
        }
        if let role, let otherRole = other.role, role != otherRole {
            return false
        }
        if let subrole, let otherSubrole = other.subrole, subrole != otherSubrole {
            return false
        }
        if let roundedFocusedElementFrame,
           let otherRoundedFocusedElementFrame = other.roundedFocusedElementFrame,
           roundedFocusedElementFrame != otherRoundedFocusedElementFrame {
            return false
        }

        return true
    }

    private func isSameGoogleDocsVolatileLineTarget(as other: StableFieldIdentity) -> Bool {
        guard bundleID == "com.google.Chrome",
              hasGoogleDocsDomain(domain) || hasGoogleDocsDomain(other.domain),
              compatible(domain, other.domain),
              compatible(role, other.role),
              compatible(subrole, other.subrole),
              let roundedFocusedElementFrame,
              let otherRoundedFocusedElementFrame = other.roundedFocusedElementFrame else {
            return false
        }

        return Self.isGoogleDocsVolatileLineMetric(roundedFocusedElementFrame)
            && Self.isGoogleDocsVolatileLineMetric(otherRoundedFocusedElementFrame)
    }

    private func hasGoogleDocsDomain(_ value: String?) -> Bool {
        value?.contains("docs.google.com") == true
    }

    private func compatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return lhs == rhs
    }

    public static func isGoogleDocsVolatileLineMetric(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 80
            && rect.height > 0
            && rect.height <= 80
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
