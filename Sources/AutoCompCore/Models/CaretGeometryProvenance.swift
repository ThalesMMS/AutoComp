import CoreGraphics
import Foundation

public enum CaretGeometryProvenance: String, Codable, CaseIterable, Sendable {
    case nativeSelectedRange
    case nativeCharacterBounds
    case measuredTextRun
    case webAccessibilityBridge
    case textMarkerFallback
    case lineMetricFallback
    case focusedElementFrame
    case screenOCR
    case hiddenTextLayoutEstimate
    case unknown

    public var isAuthoritativeMeasurement: Bool {
        switch self {
        case .nativeSelectedRange, .nativeCharacterBounds, .measuredTextRun:
            return true
        default:
            return false
        }
    }
}

public enum CaretGeometryCoordinateSpace: String, Codable, CaseIterable, Sendable {
    /// Accessibility global coordinates: origin at the upper-left of the main display.
    case accessibilityGlobal
    /// AppKit global coordinates: origin at the lower-left of the main display.
    case appKitGlobal
    /// Coordinates relative to one display. Must be converted before global comparisons.
    case screenLocal
    case unknown
}

public enum CaretGeometryAuthorityDecision: String, Codable, Equatable, Sendable {
    case keepExisting
    case candidateForDiagnosticsOnly
    case useCandidate
    case degradePresentationTier
    case suppress
}

public struct CaretGeometryAuthorityPolicy: Sendable {
    public var webBridgeVerticalReplacementThreshold: CGFloat

    public init(webBridgeVerticalReplacementThreshold: CGFloat = 12) {
        self.webBridgeVerticalReplacementThreshold = max(1, webBridgeVerticalReplacementThreshold)
    }

    public func decision(
        existingQuality: CaretGeometryQuality,
        existingProvenance: CaretGeometryProvenance,
        candidateProvenance: CaretGeometryProvenance,
        hostBundleID: String,
        verticalDelta: CGFloat? = nil,
        hasIndependentEvidence: Bool = false,
        pendingInsertion: String? = nil
    ) -> CaretGeometryAuthorityDecision {
        if existingProvenance.isAuthoritativeMeasurement {
            return .keepExisting
        }

        if existingProvenance == .textMarkerFallback,
           !candidateProvenance.isAuthoritativeMeasurement {
            return .keepExisting
        }

        if existingProvenance == .screenOCR {
            return candidateProvenance.isAuthoritativeMeasurement
                ? .useCandidate
                : .candidateForDiagnosticsOnly
        }

        if existingProvenance == .unknown,
           candidateProvenance == .hiddenTextLayoutEstimate {
            return .useCandidate
        }

        if existingProvenance == .webAccessibilityBridge,
           candidateProvenance == .hiddenTextLayoutEstimate {
            guard WebHostApps.isWebLike(hostBundleID),
                  hasIndependentEvidence,
                  abs(verticalDelta ?? 0) >= webBridgeVerticalReplacementThreshold else {
                return .keepExisting
            }
            return .useCandidate
        }

        switch existingQuality {
        case .elementFrame, .unavailable:
            if candidateProvenance == .hiddenTextLayoutEstimate,
               pendingInsertion?.contains("\n") == true {
                return .useCandidate
            }
            return .useCandidate
        case .screenOCR:
            return .candidateForDiagnosticsOnly
        case .directCaret, .glyph, .lineMetric:
            return candidateProvenance.isAuthoritativeMeasurement
                ? .useCandidate
                : .keepExisting
        }
    }
}
