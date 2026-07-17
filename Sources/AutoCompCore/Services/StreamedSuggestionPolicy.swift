import Foundation

public enum StreamedSuggestionRejection: String, Equatable, Sendable {
    case empty
    case duplicate
    case outOfOrder = "out-of-order"
    case nonMonotonic = "non-monotonic"
    case controlMarker = "control-marker"
    case unsafeSeam = "unsafe-seam"
}

public enum StreamedSuggestionDecision: Equatable, Sendable {
    case render(String)
    case finalizeCurrent
    case ignore(StreamedSuggestionRejection)
    case keepCurrent(StreamedSuggestionRejection)
    case hide(StreamedSuggestionRejection)
}

public struct StreamedSuggestionPolicy: Sendable {
    private(set) public var renderedText: String?
    private(set) public var lastProviderSequence: Int = -1
    private let seamValidator: CompletionSeamValidator

    public init(seamValidator: CompletionSeamValidator = CompletionSeamValidator()) {
        self.seamValidator = seamValidator
    }

    public mutating func evaluate(
        _ partial: CompletionPartial,
        context: TextContext
    ) -> StreamedSuggestionDecision {
        guard partial.providerSequence > lastProviderSequence else {
            return terminalDecision(for: partial, rejection: .outOfOrder)
        }
        lastProviderSequence = partial.providerSequence

        let candidate = safelyNormalized(partial.accumulatedText, context: context)
        guard !candidate.isEmpty else {
            return terminalDecision(for: partial, rejection: .empty)
        }
        guard !containsControlMarker(candidate) else {
            return terminalDecision(for: partial, rejection: .controlMarker)
        }
        guard seamValidator.validate(
            candidate: candidate,
            before: context.textBeforeCursor,
            after: context.textAfterCursor
        ) == .allow else {
            return terminalDecision(for: partial, rejection: .unsafeSeam)
        }

        if let renderedText {
            if candidate == renderedText {
                return partial.isFinal ? .finalizeCurrent : .ignore(.duplicate)
            }
            guard candidate.hasPrefix(renderedText) else {
                return terminalDecision(for: partial, rejection: .nonMonotonic)
            }
        }

        renderedText = candidate
        return .render(candidate)
    }

    private func safelyNormalized(_ candidate: String, context: TextContext) -> String {
        let canonical = candidate.precomposedStringWithCanonicalMapping
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: canonical,
            latencyMs: 0
        )
        switch SuggestionPublicationPolicy.evaluate(suggestion, for: context) {
        case .publish(let normalized):
            return normalized.visibleText
        case .suppressEmpty:
            return ""
        }
    }

    private func terminalDecision(
        for partial: CompletionPartial,
        rejection: StreamedSuggestionRejection
    ) -> StreamedSuggestionDecision {
        guard partial.isFinal else { return .ignore(rejection) }
        return renderedText == nil ? .hide(rejection) : .keepCurrent(rejection)
    }

    private func containsControlMarker(_ candidate: String) -> Bool {
        let markers = ["<|", "|>", "[INST]", "[/INST]", "<start_of_turn>", "<end_of_turn>"]
        if markers.contains(where: candidate.contains) { return true }
        return candidate.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                && scalar != "\n" && scalar != "\r" && scalar != "\t"
        }
    }
}

