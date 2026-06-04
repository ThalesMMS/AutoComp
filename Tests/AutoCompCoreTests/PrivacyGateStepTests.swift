import AutoCompCore
import XCTest

final class PrivacyGateStepTests: XCTestCase {
    func testAllowsWhenCollectionEnabledAndNoRules() async {
        var context = requestContext(privacySettings: PrivacySettings(collectionEnabled: true))
        let step = SuggestionPipeline.PrivacyGateStep<String>()

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .continue)
    }

    func testDiscardsWhenCollectionDisabled() async {
        var context = requestContext(privacySettings: PrivacySettings(collectionEnabled: false))
        let step = SuggestionPipeline.PrivacyGateStep<String>()

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "collection-not-allowed:collection-disabled")))
    }

    func testDiscardsWhenSecureField() async {
        var context = requestContext(
            privacySettings: PrivacySettings(collectionEnabled: true),
            isSecureField: true
        )
        let step = SuggestionPipeline.PrivacyGateStep<String>()

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "secure-field")))
    }

    func testDiscardsWhenDomainRuleDenies() async {
        var settings = PrivacySettings(collectionEnabled: true)
        settings.perDomainRules = ["example.com": false]

        var context = requestContext(
            privacySettings: settings,
            domain: "https://example.com/some/path"
        )
        let step = SuggestionPipeline.PrivacyGateStep<String>()

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "collection-not-allowed:domain-rule")))
    }

    func testDiscardsWhenAppRuleDenies() async {
        var settings = PrivacySettings(collectionEnabled: true)
        settings.perAppRules = ["com.example.app": false]

        var context = requestContext(privacySettings: settings)
        let step = SuggestionPipeline.PrivacyGateStep<String>()

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "collection-not-allowed:app-rule")))
    }

    private func requestContext(
        privacySettings: PrivacySettings,
        domain: String? = nil,
        isSecureField: Bool = false
    ) -> SuggestionPipeline.RequestContext {
        SuggestionPipeline.RequestContext(
            textContext: TextContext(
                app: .init(bundleID: "com.example.app", displayName: "Example", processID: 1),
                domain: domain,
                focusedElementID: "field",
                textBeforeCursor: "hello"
            ),
            privacySettings: privacySettings,
            isSecureField: isSecureField
        )
    }
}
