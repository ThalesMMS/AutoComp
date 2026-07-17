import AutoCompCore
import XCTest

final class FrozenPromptSideContextTests: XCTestCase {
    func testFreezesVisualAndPersonalizationWithinFieldTTL() async {
        let store = FrozenPromptSideContextStore(ttl: 5)
        let now = Date(timeIntervalSince1970: 1_000)
        let privacy = allowedPrivacy()
        let originalSample = sample("original")

        _ = await store.resolve(
            textContext: context(),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "original visual"),
            clipboardContext: nil,
            personalizationSamples: [originalSample],
            now: now
        )
        let second = await store.resolve(
            textContext: context(text: "hello world"),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "new visual"),
            clipboardContext: nil,
            personalizationSamples: [sample("new")],
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(second.context.visualContext?.summary, "original visual")
        XCTAssertEqual(second.context.personalizationSamples, [originalSample])
        XCTAssertNil(second.resetReason)
    }

    func testMeaningfulClipboardChangeRefreshesOnlyClipboardAndForcesReset() async {
        let store = FrozenPromptSideContextStore(ttl: 5)
        let now = Date(timeIntervalSince1970: 1_000)
        let privacy = allowedPrivacy()
        _ = await store.resolve(
            textContext: context(),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "frozen visual"),
            clipboardContext: clipboard("first"),
            personalizationSamples: [],
            now: now
        )

        let resolution = await store.resolve(
            textContext: context(text: "hello "),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "new visual"),
            clipboardContext: clipboard("second"),
            personalizationSamples: [],
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(resolution.context.clipboardContext?.summary, "second")
        XCTAssertEqual(resolution.context.visualContext?.summary, "frozen visual")
        XCTAssertEqual(resolution.resetReason, .sideContextChanged)
    }

    func testNilClipboardDoesNotDestabilizeFrozenHead() async {
        let store = FrozenPromptSideContextStore(ttl: 5)
        let now = Date(timeIntervalSince1970: 1_000)
        let privacy = allowedPrivacy()
        _ = await store.resolve(
            textContext: context(),
            privacySettings: privacy,
            visualContext: nil,
            clipboardContext: nil,
            personalizationSamples: [],
            now: now
        )

        let resolution = await store.resolve(
            textContext: context(text: "hello "),
            privacySettings: privacy,
            visualContext: nil,
            clipboardContext: nil,
            personalizationSamples: [],
            now: now.addingTimeInterval(1)
        )

        XCTAssertNil(resolution.context.clipboardContext)
        XCTAssertNil(resolution.resetReason)
    }

    func testFreezesLanguageAndCaptureSourceMetadataWithinTTL() async {
        let store = FrozenPromptSideContextStore(ttl: 5)
        let now = Date(timeIntervalSince1970: 1_000)
        _ = await store.resolve(
            textContext: context(sources: [.accessibility], languageHint: "en"),
            privacySettings: allowedPrivacy(),
            visualContext: nil,
            clipboardContext: nil,
            personalizationSamples: [],
            now: now
        )

        let resolution = await store.resolve(
            textContext: context(
                text: "hello ",
                sources: [.accessibility, .screenOCR],
                languageHint: "pt"
            ),
            privacySettings: allowedPrivacy(),
            visualContext: nil,
            clipboardContext: nil,
            personalizationSamples: [],
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(resolution.context.languageHint, "en")
        XCTAssertEqual(resolution.context.captureSources, [.accessibility])
        XCTAssertNil(resolution.resetReason)
    }

    func testPrivacyRevocationImmediatelyClearsFrozenContent() async {
        let store = FrozenPromptSideContextStore(ttl: 5)
        let now = Date(timeIntervalSince1970: 1_000)
        _ = await store.resolve(
            textContext: context(),
            privacySettings: allowedPrivacy(),
            visualContext: VisualContextSnapshot(summary: "visual"),
            clipboardContext: clipboard("clipboard"),
            personalizationSamples: [sample("sample")],
            now: now
        )

        let revoked = await store.resolve(
            textContext: context(text: "hello "),
            privacySettings: PrivacySettings(),
            visualContext: VisualContextSnapshot(summary: "must not survive"),
            clipboardContext: clipboard("must not survive"),
            personalizationSamples: [sample("must not survive")],
            now: now.addingTimeInterval(1)
        )

        XCTAssertNil(revoked.context.visualContext)
        XCTAssertNil(revoked.context.clipboardContext)
        XCTAssertTrue(revoked.context.personalizationSamples.isEmpty)
        XCTAssertEqual(revoked.resetReason, .privacyChanged)
    }

    func testTTLAndFieldChangeRebuildDeterministically() async {
        let store = FrozenPromptSideContextStore(ttl: 1)
        let now = Date(timeIntervalSince1970: 1_000)
        let privacy = allowedPrivacy()
        _ = await store.resolve(
            textContext: context(),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "one"),
            clipboardContext: nil,
            personalizationSamples: [],
            now: now
        )
        let expired = await store.resolve(
            textContext: context(text: "hello "),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "two"),
            clipboardContext: nil,
            personalizationSamples: [],
            now: now.addingTimeInterval(2)
        )
        let changedField = await store.resolve(
            textContext: context(text: "hello ", fieldID: "other"),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "three"),
            clipboardContext: nil,
            personalizationSamples: [],
            now: now.addingTimeInterval(2.1)
        )

        XCTAssertEqual(expired.context.visualContext?.summary, "two")
        XCTAssertEqual(expired.resetReason, .ttlExpired)
        XCTAssertEqual(changedField.context.visualContext?.summary, "three")
        XCTAssertEqual(changedField.resetReason, .fieldChanged)
    }

    func testLowTrustContextNeverInheritsFrozenSensitiveSideContext() async {
        let store = FrozenPromptSideContextStore()
        let privacy = allowedPrivacy()
        _ = await store.resolve(
            textContext: context(),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "visual"),
            clipboardContext: clipboard("clipboard"),
            personalizationSamples: [sample("sample")]
        )
        let lowTrust = await store.resolve(
            textContext: context(sources: [.keystrokeBufferLowTrust]),
            privacySettings: privacy,
            visualContext: VisualContextSnapshot(summary: "new"),
            clipboardContext: clipboard("new"),
            personalizationSamples: [sample("new")]
        )

        XCTAssertNil(lowTrust.context.visualContext)
        XCTAssertNil(lowTrust.context.clipboardContext)
        XCTAssertTrue(lowTrust.context.personalizationSamples.isEmpty)
        XCTAssertEqual(lowTrust.resetReason, .sideContextChanged)
    }

    private func allowedPrivacy() -> PrivacySettings {
        PrivacySettings(
            clipboardContextEnabled: true,
            screenContextEnabled: true,
            localPersonalizationEnabled: true
        )
    }

    private func context(
        text: String = "hello",
        fieldID: String = "field",
        sources: Set<TextCaptureSource> = [.accessibility],
        languageHint: String? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: fieldID,
            textBeforeCursor: text,
            languageHint: languageHint,
            captureSources: sources
        )
    }

    private func clipboard(_ text: String) -> ClipboardContextSnapshot {
        ClipboardContextSnapshot(summary: text, status: .included, captureSources: [.clipboard])
    }

    private func sample(_ text: String) -> PersonalizationSample {
        PersonalizationSample(
            excerpt: text,
            appBundleID: "com.apple.TextEdit",
            domain: nil,
            languageHint: "en",
            createdAt: Date(timeIntervalSince1970: 1)
        )
    }
}
