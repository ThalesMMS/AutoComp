import CoreGraphics
import Foundation

public enum CaretOverlaySafetyDecision: String, Codable, Sendable {
    /// Caret/line metrics look trustworthy enough for inline overlay placement.
    case allowInline
    /// Metrics are not trustworthy enough for inline, but safe enough to show a popup (anchored more loosely).
    case forcePopup
    /// Metrics are so untrustworthy that we should not display anything.
    case suppress
}

public struct CaretGeometryTrustEvaluator: Sendable {
    public struct Policy: Sendable {
        public var maxCaretHeightFractionOfScreen: CGFloat
        public var maxCaretWidthFractionOfScreen: CGFloat
        public var maxCaretHeightAbsolute: CGFloat
        public var maxCaretWidthAbsolute: CGFloat

        /// Maximum allowed distance between the caret and the focused element rect (when both are present)
        /// before we consider it suspicious.
        public var maxCaretToFocusedElementDistance: CGFloat

        /// If we have a previous caret rect, maximum allowed delta for center point before we consider it a jump.
        public var maxCenterJump: CGFloat

        public init(
            maxCaretHeightFractionOfScreen: CGFloat = 0.25,
            maxCaretWidthFractionOfScreen: CGFloat = 0.05,
            maxCaretHeightAbsolute: CGFloat = 160,
            maxCaretWidthAbsolute: CGFloat = 40,
            maxCaretToFocusedElementDistance: CGFloat = 600,
            maxCenterJump: CGFloat = 900
        ) {
            self.maxCaretHeightFractionOfScreen = maxCaretHeightFractionOfScreen
            self.maxCaretWidthFractionOfScreen = maxCaretWidthFractionOfScreen
            self.maxCaretHeightAbsolute = maxCaretHeightAbsolute
            self.maxCaretWidthAbsolute = maxCaretWidthAbsolute
            self.maxCaretToFocusedElementDistance = maxCaretToFocusedElementDistance
            self.maxCenterJump = maxCenterJump
        }
    }

    public static let `default` = CaretGeometryTrustEvaluator()

    private let policy: Policy

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    public func evaluate(
        caretRect: CGRect?,
        focusedElementRect: CGRect?,
        screenBounds: CGRect?,
        quality: CaretGeometryQuality,
        previousCaretRect: CGRect? = nil
    ) -> CaretOverlaySafetyDecision {
        // No caret at all => we cannot do inline overlay; popup might still be ok.
        guard let caretRect else {
            return quality == .unavailable ? .suppress : .forcePopup
        }

        guard caretRect.isFinite else {
            return .suppress
        }

        // Empty/near-empty caret rect is a common AX failure mode.
        guard caretRect.width > 0, caretRect.height > 0 else {
            return .forcePopup
        }

        if let screenBounds {
            // Absurd sizes relative to screen indicate bogus coordinate spaces.
            let maxH = max(policy.maxCaretHeightAbsolute, screenBounds.height * policy.maxCaretHeightFractionOfScreen)
            let maxW = max(policy.maxCaretWidthAbsolute, screenBounds.width * policy.maxCaretWidthFractionOfScreen)
            if caretRect.height > maxH || caretRect.width > maxW {
                return .forcePopup
            }

            // If it’s entirely offscreen, suppress.
            if !caretRect.intersects(screenBounds) {
                return .suppress
            }
        }

        if let focusedElementRect {
            // If caret is wildly far from the focused element, treat as untrusted.
            let caretCenter = CGPoint(x: caretRect.midX, y: caretRect.midY)
            let elementCenter = CGPoint(x: focusedElementRect.midX, y: focusedElementRect.midY)
            let dx = caretCenter.x - elementCenter.x
            let dy = caretCenter.y - elementCenter.y
            let distance = hypot(dx, dy)
            if distance > policy.maxCaretToFocusedElementDistance {
                return .forcePopup
            }
        }

        if let previousCaretRect {
            let prevCenter = CGPoint(x: previousCaretRect.midX, y: previousCaretRect.midY)
            let center = CGPoint(x: caretRect.midX, y: caretRect.midY)
            let jump = hypot(center.x - prevCenter.x, center.y - prevCenter.y)
            if jump > policy.maxCenterJump {
                return .forcePopup
            }
        }

        // Quality-based gating: only direct caret/glyph/line metrics can be used for inline overlay.
        switch quality {
        case .directCaret, .glyph, .lineMetric:
            return .allowInline
        case .elementFrame, .screenOCR:
            return .forcePopup
        case .unavailable:
            return .suppress
        }
    }
}

private extension CGRect {
    var isFinite: Bool {
        minX.isFinite && minY.isFinite && width.isFinite && height.isFinite
    }
}
