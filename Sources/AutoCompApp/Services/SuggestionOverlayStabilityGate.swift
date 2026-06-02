import AutoCompCore
import CoreGraphics
import Foundation

struct SuggestionOverlayStabilityGate: Equatable {
    struct Configuration: Equatable {
        /// AX geometry can jitter by fractions of a point across repolls. Treat up to 1 pt as stable.
        static let defaultRectTolerance: CGFloat = 1.0

        /// After insertion, host apps often publish a few unstable caret snapshots before settling.
        static let defaultPostAcceptanceReconciliationWindow: TimeInterval = 0.45

        var rectTolerance: CGFloat
        var postAcceptanceReconciliationWindow: TimeInterval

        init(
            rectTolerance: CGFloat = Self.defaultRectTolerance,
            postAcceptanceReconciliationWindow: TimeInterval = Self.defaultPostAcceptanceReconciliationWindow
        ) {
            self.rectTolerance = rectTolerance
            self.postAcceptanceReconciliationWindow = postAcceptanceReconciliationWindow
        }
    }

    struct Snapshot: Equatable {
        let visibleText: String
        let acceptedPrefix: String
        let appBundleID: String
        let appProcessID: Int32
        let domain: String?
        let focusedElementID: String
        let stableFieldIdentity: StableFieldIdentity?
        let focusedElementRect: CGRect?
        let caretRect: CGRect?
        let displayMode: SuggestionDisplayMode
        let presentationTier: PreviewPresentationTier

        init(
            suggestion: Suggestion,
            context: TextContext,
            displayMode: SuggestionDisplayMode,
            presentationTier: PreviewPresentationTier
        ) {
            self.visibleText = suggestion.visibleText
            self.acceptedPrefix = suggestion.acceptedPrefix
            self.appBundleID = context.app.bundleID
            self.appProcessID = context.app.processID
            self.domain = context.domain
            self.focusedElementID = context.focusedElementID
            self.stableFieldIdentity = context.stableFieldIdentity
            self.focusedElementRect = context.focusedElementRect
            self.caretRect = context.caretRect
            self.displayMode = displayMode
            self.presentationTier = presentationTier
        }
    }

    enum Decision: Equatable {
        case present(reason: Reason)
        case skip(reason: Reason)

        var shouldPresent: Bool {
            switch self {
            case .present:
                return true
            case .skip:
                return false
            }
        }

        var reason: Reason {
            switch self {
            case .present(let reason), .skip(let reason):
                return reason
            }
        }

        var diagnosticName: String {
            shouldPresent ? "present" : "skip"
        }
    }

    enum Reason: String, Equatable {
        case overlayHidden = "overlay-hidden"
        case visibleTextChanged = "visible-text-changed"
        case focusChanged = "focus-changed"
        case fieldFrameChanged = "field-frame-changed"
        case displayModeChanged = "display-mode-changed"
        case presentationTierChanged = "presentation-tier-changed"
        case caretChanged = "caret-changed"
        case stableGeometry = "stable-geometry"
        case postAcceptanceCaretDrift = "post-acceptance-caret-drift"
    }

    var configuration: Configuration = Configuration()

    func decision(
        previous: Snapshot?,
        proposed: Snapshot,
        now: Date,
        lastAcceptanceAt: Date?
    ) -> Decision {
        guard let previous else {
            return .present(reason: .overlayHidden)
        }

        if previous.visibleText != proposed.visibleText {
            return .present(reason: .visibleTextChanged)
        }

        if focusChanged(from: previous, to: proposed) {
            return .present(reason: .focusChanged)
        }

        if rectChanged(previous.focusedElementRect, proposed.focusedElementRect) {
            return .present(reason: .fieldFrameChanged)
        }

        if previous.displayMode != proposed.displayMode {
            return .present(reason: .displayModeChanged)
        }

        if previous.presentationTier != proposed.presentationTier {
            return .present(reason: .presentationTierChanged)
        }

        if rectChanged(previous.caretRect, proposed.caretRect) {
            if isReconcilingPostAcceptance(
                previous: previous,
                proposed: proposed,
                now: now,
                lastAcceptanceAt: lastAcceptanceAt
            ) {
                return .skip(reason: .postAcceptanceCaretDrift)
            }
            return .present(reason: .caretChanged)
        }

        return .skip(reason: .stableGeometry)
    }

    private func focusChanged(from previous: Snapshot, to proposed: Snapshot) -> Bool {
        guard previous.appBundleID == proposed.appBundleID,
              previous.appProcessID == proposed.appProcessID,
              previous.domain == proposed.domain else {
            return true
        }

        if let previousIdentity = previous.stableFieldIdentity,
           let proposedIdentity = proposed.stableFieldIdentity {
            return !previousIdentity.matchesStableTarget(proposedIdentity)
        }

        return previous.focusedElementID != proposed.focusedElementID
    }

    private func rectChanged(_ previous: CGRect?, _ proposed: CGRect?) -> Bool {
        switch (previous, proposed) {
        case (.none, .none):
            return false
        case (.some(let previous), .some(let proposed)):
            return abs(previous.origin.x - proposed.origin.x) > configuration.rectTolerance
                || abs(previous.origin.y - proposed.origin.y) > configuration.rectTolerance
                || abs(previous.size.width - proposed.size.width) > configuration.rectTolerance
                || abs(previous.size.height - proposed.size.height) > configuration.rectTolerance
        case (.none, .some), (.some, .none):
            return true
        }
    }

    private func isReconcilingPostAcceptance(
        previous: Snapshot,
        proposed: Snapshot,
        now: Date,
        lastAcceptanceAt: Date?
    ) -> Bool {
        guard !proposed.acceptedPrefix.isEmpty,
              proposed.acceptedPrefix == previous.acceptedPrefix,
              let lastAcceptanceAt else {
            return false
        }

        return now.timeIntervalSince(lastAcceptanceAt) <= configuration.postAcceptanceReconciliationWindow
    }
}
