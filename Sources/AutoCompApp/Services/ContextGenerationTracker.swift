import AutoCompCore
import CoreGraphics
import Foundation

struct FocusIdentity: Equatable, Sendable {
    let focusedElementID: String
    let focusedElementRect: CGRect?
    let caretRect: CGRect?
    let lineReferenceRect: CGRect?
    let isScreenOCR: Bool

    init(context: TextContext) {
        focusedElementID = context.focusedElementID
        focusedElementRect = context.focusedElementRect
        caretRect = context.caretRect
        lineReferenceRect = context.lineReferenceRect
        isScreenOCR = context.caretGeometryQuality == .screenOCR
            || context.captureSources.contains(.screenOCR)
    }

    func matches(_ other: FocusIdentity) -> Bool {
        let metricTolerance: CGFloat = isScreenOCR || other.isScreenOCR ? 16 : 4
        let elementTolerance: CGFloat = isScreenOCR || other.isScreenOCR ? 16 : 8
        return focusedElementID == other.focusedElementID
            || approximatelySameRect(focusedElementRect, other.focusedElementRect, tolerance: elementTolerance)
            || approximatelySameRect(caretRect, other.caretRect, tolerance: metricTolerance)
            || approximatelySameRect(lineReferenceRect, other.lineReferenceRect, tolerance: metricTolerance)
    }

    private func approximatelySameRect(_ lhs: CGRect?, _ rhs: CGRect?, tolerance: CGFloat) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

struct ContextGenerationTracker {
    struct Signature: Equatable, Sendable {
        let app: AppIdentity
        let domain: String?
        let focusIdentity: FocusIdentity
        let textBeforeCursor: String
        let selectedRangeLocation: Int?
        let selectedRangeLength: Int?
    }

    func signature(for context: TextContext) -> Signature {
        Signature(
            app: context.app,
            domain: context.domain,
            focusIdentity: FocusIdentity(context: context),
            textBeforeCursor: context.textBeforeCursor,
            selectedRangeLocation: context.selectedRange?.location,
            selectedRangeLength: context.selectedRange?.length
        )
    }

    func matches(_ context: TextContext, signature: Signature) -> Bool {
        let candidate = self.signature(for: context)
        return candidate.app == signature.app
            && candidate.domain == signature.domain
            && candidate.textBeforeCursor == signature.textBeforeCursor
            && candidate.selectedRangeLocation == signature.selectedRangeLocation
            && candidate.selectedRangeLength == signature.selectedRangeLength
            && signature.focusIdentity.matches(candidate.focusIdentity)
    }
}
