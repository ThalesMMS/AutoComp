import AutoCompCore
import CoreGraphics
import Foundation

struct StrictGenerationSignature: Equatable, Sendable {
    let app: AppIdentity
    let domain: String?
    let focusedElementID: String
    let focusIdentity: FocusIdentity
    let textBeforeCursor: String
    let textAfterCursor: String?
    let selectedText: String?
    let selectedRangeLocation: Int?
    let selectedRangeLength: Int?
}

struct FocusIdentity: Equatable, Sendable {
    let focusedElementID: String
    let stableFieldIdentity: StableFieldIdentity?
    let focusedElementRect: CGRect?
    let caretRect: CGRect?
    let lineReferenceRect: CGRect?
    let isScreenOCR: Bool

    init(context: TextContext) {
        focusedElementID = context.focusedElementID
        stableFieldIdentity = context.stableFieldIdentity
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

    func matchesStableField(_ other: FocusIdentity) -> Bool {
        guard let stableFieldIdentity,
              let otherStableFieldIdentity = other.stableFieldIdentity else {
            return false
        }
        return stableFieldIdentity.matchesStableTarget(otherStableFieldIdentity)
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
    func signature(for context: TextContext) -> StrictGenerationSignature {
        StrictGenerationSignature(
            app: context.app,
            domain: context.domain,
            focusedElementID: context.focusedElementID,
            focusIdentity: FocusIdentity(context: context),
            textBeforeCursor: context.textBeforeCursor,
            textAfterCursor: context.textAfterCursor,
            selectedText: context.selectedText,
            selectedRangeLocation: context.selectedRange?.location,
            selectedRangeLength: context.selectedRange?.length
        )
    }

    func matches(_ context: TextContext, signature: StrictGenerationSignature) -> Bool {
        let candidate = self.signature(for: context)
        let exactTextMatches = candidate.textBeforeCursor == signature.textBeforeCursor
        let textMatches = exactTextMatches
            || isTrailingWhitespaceNormalization(candidate.textBeforeCursor, signature.textBeforeCursor, for: candidate)
        let selectionMatches = candidate.selectedRangeLocation == signature.selectedRangeLocation
            && candidate.selectedRangeLength == signature.selectedRangeLength
        let selectionMatchesWhitespaceNormalization = textMatches
            && candidate.selectedRangeLength == 0
            && signature.selectedRangeLength == 0
            && isSelectionLocationConsistentWithTrailingWhitespaceNormalization(
                candidate.selectedRangeLocation,
                signature.selectedRangeLocation,
                candidateText: candidate.textBeforeCursor,
                signatureText: signature.textBeforeCursor
            )
        let focusMatches = signature.focusIdentity.matches(candidate.focusIdentity)
            || isGoogleDocsScreenOCRFocusIdentityChurn(
                candidate: candidate,
                signature: signature,
                exactTextMatches: exactTextMatches,
                selectionMatches: selectionMatches
            )

        return candidate.app == signature.app
            && candidate.domain == signature.domain
            && textMatches
            && candidate.textAfterCursor == signature.textAfterCursor
            && candidate.selectedText == signature.selectedText
            && (selectionMatches || selectionMatchesWhitespaceNormalization)
            && focusMatches
    }

    private func isTrailingWhitespaceNormalization(
        _ candidateText: String,
        _ signatureText: String,
        for candidate: StrictGenerationSignature
    ) -> Bool {
        guard isWebLikeContext(candidate) else {
            return false
        }

        return droppingTrailingWhitespace(candidateText) == droppingTrailingWhitespace(signatureText)
            && candidateText != signatureText
            && (endsWithWhitespace(candidateText) || endsWithWhitespace(signatureText))
    }

    private func isSelectionLocationConsistentWithTrailingWhitespaceNormalization(
        _ candidateLocation: Int?,
        _ signatureLocation: Int?,
        candidateText: String,
        signatureText: String
    ) -> Bool {
        guard let candidateLocation, let signatureLocation else {
            return false
        }

        let lengthDelta = abs((candidateText as NSString).length - (signatureText as NSString).length)
        return abs(candidateLocation - signatureLocation) <= max(1, lengthDelta)
    }

    private func isWebLikeContext(_ signature: StrictGenerationSignature) -> Bool {
        [
            "com.openai.codex",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.todesktop.230313mzl4w4u92"
        ].contains(signature.app.bundleID)
    }

    private func isGoogleDocsScreenOCRFocusIdentityChurn(
        candidate: StrictGenerationSignature,
        signature: StrictGenerationSignature,
        exactTextMatches: Bool,
        selectionMatches: Bool
    ) -> Bool {
        guard exactTextMatches,
              selectionMatches,
              candidate.selectedRangeLength == 0,
              signature.selectedRangeLength == 0,
              candidate.domain?.contains("docs.google.com") == true,
              signature.domain?.contains("docs.google.com") == true,
              isWebLikeContext(candidate),
              isWebLikeContext(signature),
              candidate.focusIdentity.isScreenOCR || signature.focusIdentity.isScreenOCR else {
            return false
        }

        return true
    }

    private func droppingTrailingWhitespace(_ text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    private func endsWithWhitespace(_ text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar)
    }
}
