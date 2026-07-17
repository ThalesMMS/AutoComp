import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class InlineCommandCoordinatorTests: XCTestCase {
    func testOnlyFirstClaimingControllerBecomesActive() async {
        let emoji = FakeInlineCommandController(kind: .emoji, claimsNextEvent: true)
        let macro = FakeInlineCommandController(kind: .macro, claimsNextEvent: true)
        let coordinator = InlineCommandCoordinator(controllers: [emoji, macro])

        let handled = await coordinator.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        XCTAssertTrue(handled)
        XCTAssertTrue(emoji.isActive)
        XCTAssertFalse(macro.isActive)
        XCTAssertEqual(coordinator.captureState?.kind, .emoji)
        XCTAssertEqual(emoji.eventCount, 1)
        XCTAssertEqual(macro.eventCount, 0)
    }

    func testActiveControllerGetsFirstLookAndSuspendsOthers() async {
        let emoji = FakeInlineCommandController(kind: .emoji, claimsNextEvent: true)
        let macro = FakeInlineCommandController(kind: .macro, claimsNextEvent: false)
        let coordinator = InlineCommandCoordinator(controllers: [emoji, macro])
        _ = await coordinator.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        emoji.claimsNextEvent = false

        _ = await coordinator.handleInputEvent(.text(keyCode: 1, isSuggestionTrigger: false))

        XCTAssertEqual(emoji.eventCount, 2)
        XCTAssertEqual(macro.eventCount, 0)
    }

    func testCompositionAndPipelineSuspensionCancelActiveCapture() async {
        var inputMethod = InputMethodState.asciiCompatible
        let macro = FakeInlineCommandController(kind: .macro, claimsNextEvent: true)
        let coordinator = InlineCommandCoordinator(
            controllers: [macro],
            inputMethodStateProvider: { inputMethod }
        )
        _ = await coordinator.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        XCTAssertTrue(macro.isActive)

        inputMethod = InputMethodState(
            isASCIICompatible: false,
            isComposingText: true,
            currentInputSourceID: "ime"
        )
        let compositionHandled = await coordinator.handleInputEvent(.text(keyCode: 1, isSuggestionTrigger: false))
        XCTAssertTrue(compositionHandled)
        XCTAssertFalse(macro.isActive)
        XCTAssertEqual(macro.lastCancelReason, .compositionActive)

        macro.claimsNextEvent = true
        inputMethod = .asciiCompatible
        _ = await coordinator.handleInputEvent(.text(keyCode: 2, isSuggestionTrigger: false))
        coordinator.setPipelineSuspended(true)
        XCTAssertFalse(macro.isActive)
        XCTAssertEqual(macro.lastCancelReason, .pipelineSuspended)
    }

    func testDiagnosticsEmitContentFreeCorrelatedCompletionTraceEvents() {
        let recorder = InlineCommandTraceRecorder()
        let diagnostics = InlineCommandDiagnostics(traceRecorder: recorder)

        diagnostics.record(kind: .macro, reason: .opened, queryUTF16Length: 0)
        diagnostics.record(kind: .macro, reason: .updated, queryUTF16Length: 4)
        diagnostics.record(kind: .macro, reason: .committed, queryUTF16Length: 4)

        let events = recorder.events
        XCTAssertEqual(events.map(\.event), [
            .inlineCommandOpened,
            .inlineCommandUpdated,
            .inlineCommandCommitted
        ])
        XCTAssertEqual(Set(events.map(\.traceID)).count, 1)
        XCTAssertEqual(events.map(\.inlineCommandKind), [.macro, .macro, .macro])
        XCTAssertEqual(events.map(\.inlineCommandQueryUTF16Length), [0, 4, 4])
        XCTAssertEqual(events.last?.outcome, .inserted)
    }
}

private final class InlineCommandTraceRecorder: CompletionTraceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CompletionTraceEvent] = []

    var events: [CompletionTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: CompletionTraceEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

@MainActor
private final class FakeInlineCommandController: InlineCommandControlling {
    let kind: InlineCommandKind
    var onActiveChanged: ((Bool) -> Void)?
    var isActive = false
    var captureState: InlineCommandCaptureState? {
        isActive ? InlineCommandCaptureState(kind: kind, queryUTF16Length: 0, stableFieldIdentity: nil) : nil
    }
    var keyboardCapabilities: InlineCommandKeyboardCapabilities { isActive ? .singleResult : .inactive }
    var claimsNextEvent: Bool
    private(set) var eventCount = 0
    private(set) var lastCancelReason: InlineCommandReason?

    init(kind: InlineCommandKind, claimsNextEvent: Bool) {
        self.kind = kind
        self.claimsNextEvent = claimsNextEvent
    }

    func handleInputEvent(_ event: CapturedInputEvent) async -> Bool {
        eventCount += 1
        if claimsNextEvent && !isActive {
            isActive = true
            onActiveChanged?(true)
        }
        return isActive
    }

    func handleKeyboardCommand(_ command: EmojiKeyboardCommand) async {}

    func cancel(reason: InlineCommandReason) {
        lastCancelReason = reason
        let wasActive = isActive
        isActive = false
        if wasActive { onActiveChanged?(false) }
    }
}
