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
        guard WebHostApps.isWebLike(candidate.app.bundleID) else {
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
              GoogleDocsContext.matches(bundleID: candidate.app.bundleID, domain: candidate.domain, appGate: .webLike),
              GoogleDocsContext.matches(bundleID: signature.app.bundleID, domain: signature.domain, appGate: .webLike),
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
