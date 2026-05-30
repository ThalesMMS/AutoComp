import AutoCompCore
import XCTest

final class PrivacyGateStepTests: XCTestCase {
    func testAllowsWhenCollectionEnabledAndNoRules() async {
        var context = SuggestionPipeline.RequestContext()
        context.userInfo["input"] = SuggestionPipeline.PrivacyGateStep<String>.Input(
            privacySettings: PrivacySettings(collectionEnabled: true),
            appBundleID: "com.example.app",
            domain: nil,
            isSecureField: false
        )

        let step = SuggestionPipeline.PrivacyGateStep<String> { ctx in
            ctx.userInfo["input"] as? SuggestionPipeline.PrivacyGateStep<String>.Input
        }

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .continue)
    }

    func testDiscardsWhenCollectionDisabled() async {
        var context = SuggestionPipeline.RequestContext()
        context.userInfo["input"] = SuggestionPipeline.PrivacyGateStep<String>.Input(
            privacySettings: PrivacySettings(collectionEnabled: false),
            appBundleID: "com.example.app",
            domain: nil,
            isSecureField: false
        )

        let step = SuggestionPipeline.PrivacyGateStep<String> { ctx in
            ctx.userInfo["input"] as? SuggestionPipeline.PrivacyGateStep<String>.Input
        }

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "collection-not-allowed:collection-disabled")))
    }

    func testDiscardsWhenSecureField() async {
        var context = SuggestionPipeline.RequestContext()
        context.userInfo["input"] = SuggestionPipeline.PrivacyGateStep<String>.Input(
            privacySettings: PrivacySettings(collectionEnabled: true),
            appBundleID: "com.example.app",
            domain: nil,
            isSecureField: true
        )

        let step = SuggestionPipeline.PrivacyGateStep<String> { ctx in
            ctx.userInfo["input"] as? SuggestionPipeline.PrivacyGateStep<String>.Input
        }

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "secure-field")))
    }

    func testDiscardsWhenDomainRuleDenies() async {
        var settings = PrivacySettings(collectionEnabled: true)
        settings.perDomainRules = ["example.com": false]

        var context = SuggestionPipeline.RequestContext()
        context.userInfo["input"] = SuggestionPipeline.PrivacyGateStep<String>.Input(
            privacySettings: settings,
            appBundleID: "com.example.app",
            domain: "https://example.com/some/path",
            isSecureField: false
        )

        let step = SuggestionPipeline.PrivacyGateStep<String> { ctx in
            ctx.userInfo["input"] as? SuggestionPipeline.PrivacyGateStep<String>.Input
        }

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "collection-not-allowed:domain-rule")))
    }

    func testDiscardsWhenAppRuleDenies() async {
        var settings = PrivacySettings(collectionEnabled: true)
        settings.perAppRules = ["com.example.app": false]

        var context = SuggestionPipeline.RequestContext()
        context.userInfo["input"] = SuggestionPipeline.PrivacyGateStep<String>.Input(
            privacySettings: settings,
            appBundleID: "com.example.app",
            domain: nil,
            isSecureField: false
        )

        let step = SuggestionPipeline.PrivacyGateStep<String> { ctx in
            ctx.userInfo["input"] as? SuggestionPipeline.PrivacyGateStep<String>.Input
        }

        let outcome = await step.handle(context: &context)
        XCTAssertEqual(outcome, .discard(.init(kind: .privacy, message: "collection-not-allowed:app-rule")))
    }
}
