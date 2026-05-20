import AutoCompCore
import XCTest

final class PromptBuilderTests: XCTestCase {
    func testPromptOmitsDisabledOptionalSources() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello there",
            captureSources: [.accessibility, .clipboard, .screenOCR]
        )

        let prompt = PromptBuilder().prompt(for: context, privacySettings: PrivacySettings())

        XCTAssertTrue(prompt.contains("accessibility"))
        XCTAssertFalse(prompt.contains("clipboard"))
        XCTAssertFalse(prompt.contains("screenOCR"))
    }

    func testPromptRendersProvidedVisualContextWithoutRefiltering() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello there"
        )
        let visualContext = VisualContextSnapshot(
            summary: "Visible title: Budget Review",
            captureSources: [.accessibility]
        )

        let prompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(screenContextEnabled: false),
            visualContext: visualContext
        )

        XCTAssertTrue(prompt.contains("Visual context:\nVisible title: Budget Review"))
    }
}
