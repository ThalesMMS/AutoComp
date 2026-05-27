import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SystemClipboardContextProviderTests: XCTestCase {
    func testPrivacyOffReturnsNoClipboardContext() async {
        let reader = FakeClipboardReader(changeCount: 2, text: "Launch plan")
        let provider = SystemClipboardContextProvider(reader: reader)

        let snapshot = provider.currentClipboardContext(
            for: context("Launch plan"),
            privacySettings: PrivacySettings(clipboardContextEnabled: false)
        )

        XCTAssertNil(snapshot)
    }

    func testClipboardAtStartupBaselineIsOmitted() async {
        let reader = FakeClipboardReader(changeCount: 4, text: "Launch plan")
        let provider = SystemClipboardContextProvider(reader: reader)

        let snapshot = provider.currentClipboardContext(
            for: context("Launch plan"),
            privacySettings: PrivacySettings(clipboardContextEnabled: true)
        )

        XCTAssertEqual(snapshot?.status, .omittedBeforeBaseline)
        XCTAssertEqual(snapshot?.captureSources, [])
    }

    func testRecentRelevantClipboardIsIncluded() async {
        let reader = FakeClipboardReader(changeCount: 1, text: "Launch plan\nUpdate onboarding")
        let provider = SystemClipboardContextProvider(reader: reader)
        reader.changeCount = 2

        let snapshot = provider.currentClipboardContext(
            for: context("Please summarize the launch plan"),
            privacySettings: PrivacySettings(clipboardContextEnabled: true)
        )

        XCTAssertEqual(snapshot?.status, .included)
        XCTAssertEqual(snapshot?.summary, "Launch plan\nUpdate onboarding")
        XCTAssertEqual(snapshot?.captureSources, [.clipboard])
    }

    func testUnrelatedClipboardIsOmittedAsNotRelevant() async {
        let reader = FakeClipboardReader(changeCount: 1, text: "Invoice total and payment method")
        let provider = SystemClipboardContextProvider(reader: reader)
        reader.changeCount = 2

        let snapshot = provider.currentClipboardContext(
            for: context("Please summarize the launch plan"),
            privacySettings: PrivacySettings(clipboardContextEnabled: true)
        )

        XCTAssertEqual(snapshot?.status, .omittedNotRelevant)
        XCTAssertEqual(snapshot?.promptPreview, "[clipboard omitted: not relevant]")
    }

    func testExpiredClipboardIsOmitted() async {
        let clock = MutableClock(date: Date(timeIntervalSince1970: 10))
        let reader = FakeClipboardReader(changeCount: 1, text: "Launch plan")
        let provider = SystemClipboardContextProvider(
            reader: reader,
            ttl: 5,
            now: { clock.date }
        )
        reader.changeCount = 2

        _ = provider.currentClipboardContext(
            for: context("Launch plan"),
            privacySettings: PrivacySettings(clipboardContextEnabled: true)
        )
        clock.date = Date(timeIntervalSince1970: 16)

        let snapshot = provider.currentClipboardContext(
            for: context("Launch plan"),
            privacySettings: PrivacySettings(clipboardContextEnabled: true)
        )

        XCTAssertEqual(snapshot?.status, .omittedExpired)
    }

    private func context(_ textBeforeCursor: String) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor
        )
    }
}

private final class FakeClipboardReader: ClipboardReading, @unchecked Sendable {
    var changeCount: Int
    var text: String?

    init(changeCount: Int, text: String?) {
        self.changeCount = changeCount
        self.text = text
    }

    func stringValue() -> String? {
        text
    }
}

private final class MutableClock: @unchecked Sendable {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}
