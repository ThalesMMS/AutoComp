import AutoCompCore
import Foundation

struct SuggestionEligibilityCoordinator {
    struct Result: Equatable {
        let decision: SuggestionEligibilityDecision
        let domainRuleSkipReason: SuggestionEligibilitySkipReason?
    }

    private let evaluator: SuggestionEligibilityEvaluator
    private let domainRuleResolver: DomainRuleResolver

    init(
        evaluator: SuggestionEligibilityEvaluator = SuggestionEligibilityEvaluator(),
        domainRuleResolver: DomainRuleResolver = DomainRuleResolver()
    ) {
        self.evaluator = evaluator
        self.domainRuleResolver = domainRuleResolver
    }

    func evaluate(
        context: TextContext,
        previousContext: TextContext?,
        compatibilityDecision: CompatibilityDecision,
        userRuleset: DomainWebAppRuleset,
        invocation: SuggestionEligibilityInvocation,
        inputMethodState: InputMethodState,
        lastSuggestionTriggerKeyAt: Date,
        visualContextIsReady: @autoclosure () -> Bool
    ) -> Result {
        let resolution = domainRuleResolution(for: context, userRuleset: userRuleset)

        let domainSkipReason: SuggestionEligibilitySkipReason?
        switch resolution.effectiveAction {
        case .allow, .visualContextRequired:
            domainSkipReason = nil
        case .deny:
            domainSkipReason = .domainDenied
        case .manualOnly:
            domainSkipReason = invocation == .manual ? nil : .domainManualOnly
        }

        if let domainSkipReason {
            return Result(
                decision: SuggestionEligibilityDecision(
                    outcome: .ineligible(domainSkipReason),
                    statusMessage: nil,
                    logs: []
                ),
                domainRuleSkipReason: domainSkipReason
            )
        }

        if invocation != .manual,
           case .visualContextRequired = resolution.effectiveAction,
           !visualContextIsReady() {
            return Result(
                decision: SuggestionEligibilityDecision(
                    outcome: .ineligible(.domainNeedsVisualContext),
                    statusMessage: "Visual context required",
                    logs: []
                ),
                domainRuleSkipReason: .domainNeedsVisualContext
            )
        }

        return Result(
            decision: evaluator.evaluate(
                context: context,
                previousContext: previousContext,
                compatibilityDecision: compatibilityDecision,
                lastSuggestionTriggerKeyAt: lastSuggestionTriggerKeyAt,
                invocation: invocation,
                inputMethodState: inputMethodState
            ),
            domainRuleSkipReason: nil
        )
    }

    func allowsVisualContextPreparation(
        for context: TextContext,
        userRuleset: DomainWebAppRuleset
    ) -> Bool {
        if case .deny = domainRuleResolution(for: context, userRuleset: userRuleset).effectiveAction {
            return false
        }
        return true
    }

    private func domainRuleResolution(
        for context: TextContext,
        userRuleset: DomainWebAppRuleset
    ) -> DomainRuleResolver.Resolution {
        domainRuleResolver.resolve(
            input: DomainRuleResolver.Input(
                appBundleID: context.app.bundleID,
                activeDomain: context.domain.flatMap(DomainNormalization.canonicalDomainString(from:))
            ),
            userRuleset: userRuleset,
            fallbackRuleset: .autocompleteProductionDefaults
        )
    }
}
