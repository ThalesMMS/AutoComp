import AutoCompCore
import Foundation

/// Pipeline step that publishes a finalized suggestion.
///
/// This step is explicitly `@MainActor` because it mutates UI-facing state via the
/// `SuggestionPublicationController` (which drives the overlay presenter).
@MainActor
struct PublicationStep: SuggestionPipeline.Step {
    typealias Payload = Suggestion

    private let publisher: SuggestionPublicationController
    private let publishContextProvider: @Sendable () -> PublicationContext?

    /// Additional info passed into the publish call.
    struct PublicationContext: Sendable {
        let textContext: TextContext
        let displayMode: SuggestionDisplayMode
        let collectionAllowed: Bool
    }

    init(
        publisher: SuggestionPublicationController,
        publishContextProvider: @escaping @Sendable () -> PublicationContext?
    ) {
        self.publisher = publisher
        self.publishContextProvider = publishContextProvider
    }

    func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<Suggestion> {
        guard let publicationContext = publishContextProvider() else {
            // If we no longer have a live context to publish into, treat as stale.
            return .discard(.init(kind: .stale, message: "missing-publication-context"))
        }

        guard let suggestion = context.userInfo["suggestion"] as? Suggestion else {
            return .discard(.init(kind: .other, message: "missing-suggestion"))
        }

        let result = publisher.publish(
            suggestion,
            context: publicationContext.textContext,
            displayMode: publicationContext.displayMode,
            collectionAllowed: publicationContext.collectionAllowed
        )

        if let published = result.publishedSuggestion {
            return .publish(published)
        }

        // Mirror the engine's previous behavior: a rejected publication clears state.
        return .discard(.init(kind: .ineligible, message: "publication-rejected"))
    }
}
