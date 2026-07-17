import AutoCompCore
import XCTest

final class PostAcceptanceSpeculationTests: XCTestCase {
    func testLocalFlagBuildsOptimisticContextAndSignatureMatchesPublishedHost() throws {
        let context = makeSpeculationContext(prefix: "Hello ", selection: NSRange(location: 6, length: 0))
        let policy = PostAcceptanceSpeculationPolicy(configuration: .init(enabled: true))

        let decision = policy.decision(
            context: context,
            insertedText: "world",
            route: .localLlama,
            inputMethodState: .asciiCompatible
        )

        guard case .start(let speculative) = decision else {
            return XCTFail("Expected speculation")
        }
        XCTAssertEqual(speculative.context.textBeforeCursor, "Hello world")
        XCTAssertEqual(speculative.context.selectedRange, NSRange(location: 11, length: 0))
        XCTAssertTrue(speculative.signature.matches(speculative.context))
        XCTAssertFalse(speculative.signature.matches(speculative.context.copy(textBeforeCursor: "Hello worlds")))
    }

    func testRemoteSelectionCompositionAndDisabledPolicyAreIneligible() {
        let context = makeSpeculationContext(prefix: "Hello ")
        let enabled = PostAcceptanceSpeculationPolicy(configuration: .init(enabled: true))
        XCTAssertEqual(
            enabled.decision(context: context, insertedText: "world", route: .remote, inputMethodState: .asciiCompatible),
            .ineligible(.unsupportedBackend)
        )
        XCTAssertEqual(
            enabled.decision(context: context, insertedText: "world", route: .localLlama, inputMethodState: .init(isASCIICompatible: true, isComposingText: true)),
            .ineligible(.composingText)
        )
        XCTAssertEqual(
            PostAcceptanceSpeculationPolicy(configuration: .init(enabled: false)).decision(
                context: context, insertedText: "world", route: .localLlama, inputMethodState: .asciiCompatible
            ),
            .ineligible(.disabled)
        )
        XCTAssertEqual(
            enabled.decision(
                context: makeSpeculationContext(prefix: "Hello ", selection: NSRange(location: 0, length: 2)),
                insertedText: "world", route: .localLlama, inputMethodState: .asciiCompatible
            ),
            .ineligible(.activeSelection)
        )
    }

    func testCommandBufferKeepsOneCommandAndOldTimerCannotCloseNewWindow() {
        let start = Date(timeIntervalSince1970: 100)
        var buffer = PostAcceptanceCommandBuffer()
        let first = buffer.arm(duration: 0.2, now: start)
        XCTAssertEqual(buffer.enqueue(now: start), .queued(generation: first))
        XCTAssertEqual(buffer.enqueue(now: start), .alreadyQueued(generation: first))

        let second = buffer.arm(duration: 0.5, now: start.addingTimeInterval(0.1))
        XCTAssertFalse(buffer.expire(generation: first, now: start.addingTimeInterval(0.3)))
        XCTAssertTrue(buffer.shouldIntercept(now: start.addingTimeInterval(0.3)))
        XCTAssertEqual(buffer.enqueue(now: start.addingTimeInterval(0.3)), .queued(generation: second))
        XCTAssertEqual(buffer.consume(now: start.addingTimeInterval(0.3)), second)
        XCTAssertEqual(buffer.lastCloseReason, .consumed)
    }

    func testCommandBufferExpiresFailOpenAndCanBeCancelled() {
        let start = Date(timeIntervalSince1970: 100)
        var buffer = PostAcceptanceCommandBuffer()
        let generation = buffer.arm(duration: 0.1, now: start)
        XCTAssertEqual(buffer.enqueue(now: start), .queued(generation: generation))
        XCTAssertTrue(buffer.expire(generation: generation, now: start.addingTimeInterval(0.2)))
        XCTAssertEqual(buffer.lastCloseReason, .expired)
        XCTAssertFalse(buffer.shouldIntercept(now: start.addingTimeInterval(0.2)))

        _ = buffer.arm(duration: 1, now: start)
        buffer.close(.focusChanged)
        XCTAssertEqual(buffer.lastCloseReason, .focusChanged)
        XCTAssertEqual(buffer.enqueue(now: start), .inactive)
    }

    private func makeSpeculationContext(prefix: String, selection: NSRange? = nil) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: prefix,
            selectedRange: selection
        )
    }
}
