import CoreGraphics
import Foundation

public enum TextCaptureSource: String, Codable, CaseIterable, Sendable {
    case accessibility
    case screenOCR
    case clipboard
}

public struct TextContext: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let app: AppIdentity
    public let domain: String?
    public let focusedElementID: String
    public let textBeforeCursor: String
    public let selectedRange: NSRange?
    public let caretRect: CGRect?
    public let focusedElementRect: CGRect?
    public let previousGlyphRect: CGRect?
    public let nextGlyphRect: CGRect?
    public let lineReferenceRect: CGRect?
    public let languageHint: String?
    public let captureSources: Set<TextCaptureSource>
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        app: AppIdentity,
        domain: String? = nil,
        focusedElementID: String,
        textBeforeCursor: String,
        selectedRange: NSRange? = nil,
        caretRect: CGRect? = nil,
        focusedElementRect: CGRect? = nil,
        previousGlyphRect: CGRect? = nil,
        nextGlyphRect: CGRect? = nil,
        lineReferenceRect: CGRect? = nil,
        languageHint: String? = nil,
        captureSources: Set<TextCaptureSource> = [.accessibility],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.app = app
        self.domain = domain
        self.focusedElementID = focusedElementID
        self.textBeforeCursor = textBeforeCursor
        self.selectedRange = selectedRange
        self.caretRect = caretRect
        self.focusedElementRect = focusedElementRect
        self.previousGlyphRect = previousGlyphRect
        self.nextGlyphRect = nextGlyphRect
        self.lineReferenceRect = lineReferenceRect
        self.languageHint = languageHint
        self.captureSources = captureSources
        self.createdAt = createdAt
    }
}
