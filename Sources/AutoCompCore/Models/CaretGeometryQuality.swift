import Foundation

public enum CaretGeometryQuality: String, Codable, CaseIterable, Sendable {
    case directCaret
    case glyph
    case lineMetric
    case elementFrame
    case screenOCR
    case unavailable

    public var supportsPostAcceptancePrediction: Bool {
        switch self {
        case .directCaret, .glyph, .lineMetric:
            return true
        case .elementFrame, .screenOCR, .unavailable:
            return false
        }
    }
}
