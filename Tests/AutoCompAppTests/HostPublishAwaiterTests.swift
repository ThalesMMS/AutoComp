import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class HostPublishAwaiterTests: XCTestCase {
    func testTextChangeReturnsReady() async throws {
        let baseline = testContext(textBeforeCursor: "Please")
        let changed = testContext(textBeforeCursor: "Please ")
        let provider = HostPublishTestContextProvider(context: baseline)
        let awaiter = HostPublishAwaiter(configuration: .fastTest)

        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await provider.updateContext(changed)
        }

        let result = await awaiter.awaitPublication(
            after: baseline,
            provider: provider,
            reason: "unit-text-change"
        )

        XCTAssertEqual(result.outcome, .ready)
        XCTAssertEqual(result.observedContext?.textBeforeCursor, "Please ")
    }

    func testFocusedElementAndSelectionChangesReturnReady() async throws {
        let baseline = testContext(
            focusedElementID: "field-a",
            textBeforeCursor: "Please",
            selectedRange: NSRange(location: 6, length: 0)
        )
        let elementChanged = testContext(
            focusedElementID: "field-b",
            textBeforeCursor: "Please",
            selectedRange: NSRange(location: 6, length: 0)
        )
        let elementProvider = HostPublishTestContextProvider(context: baseline)
        let elementAwaiter = HostPublishAwaiter(configuration: .fastTest)

        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await elementProvider.updateContext(elementChanged)
        }

        let elementResult = await elementAwaiter.awaitPublication(
            after: baseline,
            provider: elementProvider,
            reason: "unit-element-change"
        )
        XCTAssertEqual(elementResult.outcome, .ready)
        XCTAssertEqual(elementResult.observedContext?.focusedElementID, "field-b")

        let selectionChanged = testContext(
            focusedElementID: "field-a",
            textBeforeCursor: "Please",
            selectedRange: NSRange(location: 3, length: 2)
        )
        let selectionProvider = HostPublishTestContextProvider(context: baseline)
        let selectionAwaiter = HostPublishAwaiter(configuration: .fastTest)

        Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            await selectionProvider.updateContext(selectionChanged)
        }

        let selectionResult = await selectionAwaiter.awaitPublication(
            after: baseline,
            provider: selectionProvider,
            reason: "unit-selection-change"
        )
        XCTAssertEqual(selectionResult.outcome, .ready)
        XCTAssertEqual(selectionResult.observedContext?.selectedRange, NSRange(location: 3, length: 2))
    }

    func testNoChangeReturnsTimeout() async throws {
        let baseline = testContext(textBeforeCursor: "Please")
        let provider = HostPublishTestContextProvider(context: baseline)
        let awaiter = HostPublishAwaiter(configuration: .fastTest)

        let result = await awaiter.awaitPublication(
            after: baseline,
            provider: provider,
            reason: "unit-timeout"
        )

        XCTAssertEqual(result.outcome, .timeout)
        XCTAssertEqual(result.observedContext?.textBeforeCursor, "Please")
    }

    func testNewGenerationCancelsOlderAwait() async throws {
        let baseline = testContext(textBeforeCursor: "Please")
        let provider = HostPublishTestContextProvider(context: baseline)
        let awaiter = HostPublishAwaiter(configuration: .slowTimeoutTest)

        let olderTask = Task {
            await awaiter.awaitPublication(
                after: baseline,
                provider: provider,
                reason: "unit-old-generation"
            )
        }

        try await Task.sleep(nanoseconds: 5_000_000)
        let newerResult = await awaiter.awaitPublication(
            after: nil,
            provider: provider,
            reason: "unit-new-generation"
        )
        let olderResult = await olderTask.value

        XCTAssertEqual(newerResult.outcome, .ready)
        XCTAssertEqual(olderResult.outcome, .cancelled)
    }

    private func testContext(
        focusedElementID: String = "field-a",
        textBeforeCursor: String,
        selectedRange: NSRange? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange
        )
    }
}

private actor HostPublishTestContextProvider: TextContextProvider {
    private var context: TextContext

    init(context: TextContext) {
        self.context = context
    }

    func updateContext(_ context: TextContext) {
        self.context = context
    }

    func currentContext() async throws -> TextContext {
        context
    }
}

extension HostPublishAwaitConfiguration {
    static let fastTest = HostPublishAwaitConfiguration(
        firstReadDelayNanoseconds: 1_000_000,
        pollIntervalNanoseconds: 1_000_000,
        timeoutNanoseconds: 25_000_000
    )

    static let slowTimeoutTest = HostPublishAwaitConfiguration(
        firstReadDelayNanoseconds: 1_000_000,
        pollIntervalNanoseconds: 5_000_000,
        timeoutNanoseconds: 250_000_000
    )
}
