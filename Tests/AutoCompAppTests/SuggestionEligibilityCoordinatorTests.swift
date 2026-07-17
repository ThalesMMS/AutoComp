import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SuggestionEligibilityCoordinatorTests: XCTestCase {
    func testDomainPolicyIsResolvedOnceAndVisualReadinessIsLazy() {
        let coordinator = SuggestionEligibilityCoordinator()
        let context = TextContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "field",
            textBeforeCursor: "hello "
        )
        let ruleset = DomainWebAppRuleset(rules: [
            DomainWebAppRule(
                pattern: .exactHost("docs.google.com"),
                action: .visualContextRequired
            )
        ])
        var readinessReadCount = 0

        let result = coordinator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: CompatibilityCatalog().decision(
                bundleID: context.app.bundleID,
                domain: context.domain,
                userModeOverrides: [:]
            ),
            userRuleset: ruleset,
            invocation: .automatic,
            inputMethodState: .asciiCompatible,
            lastSuggestionTriggerKeyAt: .distantPast,
            visualContextIsReady: {
                readinessReadCount += 1
                return false
            }()
        )

        XCTAssertEqual(result.decision.skipReason, .domainNeedsVisualContext)
        XCTAssertEqual(result.domainRuleSkipReason, .domainNeedsVisualContext)
        XCTAssertEqual(readinessReadCount, 1)
    }

    func testDeniedDomainSkipsWithoutEvaluatingVisualReadiness() {
        let coordinator = SuggestionEligibilityCoordinator()
        let context = TextContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1),
            domain: "mail.google.com",
            focusedElementID: "field",
            textBeforeCursor: "hello "
        )
        var readinessReadCount = 0

        let result = coordinator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: CompatibilityCatalog().decision(
                bundleID: context.app.bundleID,
                domain: context.domain,
                userModeOverrides: [:]
            ),
            userRuleset: DomainWebAppRuleset(rules: []),
            invocation: .automatic,
            inputMethodState: .asciiCompatible,
            lastSuggestionTriggerKeyAt: .distantPast,
            visualContextIsReady: {
                readinessReadCount += 1
                return true
            }()
        )

        XCTAssertEqual(result.decision.skipReason, .domainDenied)
        XCTAssertEqual(result.domainRuleSkipReason, .domainDenied)
        XCTAssertEqual(readinessReadCount, 0)
    }
}
