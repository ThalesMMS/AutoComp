import CoreGraphics
import Foundation

public struct FocusIdentity: Equatable, Sendable {
    public let focusedElementID: String
    public let stableFieldIdentity: StableFieldIdentity?
    public let focusedElementRect: CGRect?
    public let caretRect: CGRect?
    public let lineReferenceRect: CGRect?
    public let isScreenOCR: Bool

    public init(context: TextContext) {
        focusedElementID = context.focusedElementID
        stableFieldIdentity = context.stableFieldIdentity
        focusedElementRect = context.focusedElementRect
        caretRect = context.caretRect
        lineReferenceRect = context.lineReferenceRect
        isScreenOCR = context.caretGeometryQuality == .screenOCR
            || context.captureSources.contains(.screenOCR)
    }

    public func matches(_ other: FocusIdentity) -> Bool {
        let metricTolerance: CGFloat = isScreenOCR || other.isScreenOCR ? 16 : 4
        let elementTolerance: CGFloat = isScreenOCR || other.isScreenOCR ? 16 : 8
        // Metric rects are deliberate shared-target evidence, but use tighter tolerance than the
        // focused element frame so caret/line drift does not mask a real target change.
        return focusedElementID == other.focusedElementID
            || Self.approximatelySameRect(focusedElementRect, other.focusedElementRect, tolerance: elementTolerance)
            || Self.approximatelySameRect(caretRect, other.caretRect, tolerance: metricTolerance)
            || Self.approximatelySameRect(lineReferenceRect, other.lineReferenceRect, tolerance: metricTolerance)
    }

    public func matchesStableField(_ other: FocusIdentity) -> Bool {
        guard let stableFieldIdentity,
              let otherStableFieldIdentity = other.stableFieldIdentity else {
            return false
        }
        return stableFieldIdentity.matchesStableTarget(otherStableFieldIdentity)
    }

    private static func approximatelySameRect(_ lhs: CGRect?, _ rhs: CGRect?, tolerance: CGFloat) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

public enum InteractionTargetMatcher {
    public static func matches(_ context: TextContext, as previousContext: TextContext) -> Bool {
        guard context.app == previousContext.app,
              context.domain == previousContext.domain else {
            return false
        }

        return matches(
            context,
            app: previousContext.app,
            domain: previousContext.domain,
            focusIdentity: FocusIdentity(context: previousContext)
        )
    }

    public static func matches(
        _ context: TextContext,
        app: AppIdentity,
        domain: String?,
        focusIdentity: FocusIdentity
    ) -> Bool {
        guard context.app == app,
              context.domain == domain else {
            return false
        }

        let contextFocusIdentity = FocusIdentity(context: context)
        return contextFocusIdentity.matchesStableField(focusIdentity)
            || contextFocusIdentity.matches(focusIdentity)
            || isSameGoogleDocsVolatileLineTarget(
                app: context.app,
                domain: context.domain,
                context.focusedElementRect,
                focusIdentity.focusedElementRect
            )
    }

    private static func isSameGoogleDocsVolatileLineTarget(
        app: AppIdentity,
        domain: String?,
        _ lhs: CGRect?,
        _ rhs: CGRect?
    ) -> Bool {
        guard app.bundleID == "com.google.Chrome",
              domain?.contains("docs.google.com") == true,
              let lhs,
              let rhs else {
            return false
        }

        return StableFieldIdentity.isGoogleDocsVolatileLineMetric(lhs)
            && StableFieldIdentity.isGoogleDocsVolatileLineMetric(rhs)
    }
}
