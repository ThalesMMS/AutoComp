import AutoCompCore
import XCTest

final class SuggestionReuseStoreTests: XCTestCase {
    func testRankTwoPromotionReturnsOnlyRemainingText() {
        var store = makeStore()
        let context = makeContext(prefix: "Write ")
        store.record(snapshot(context: context, candidates: ["first option", "second branch"]))

        let decision = store.decision(
            for: makeContext(prefix: "Write sec"),
            backend: .remote,
            mutation: .append
        )

        guard case .promoteAppend(let match) = decision else { return XCTFail("Expected promotion") }
        XCTAssertEqual(match.remainingText, "ond branch")
        XCTAssertEqual(match.sourceRank, 1)
    }

    func testShortRollbackRestoresRecentCandidate() {
        var store = makeStore()
        let context = makeContext(prefix: "Write ")
        store.record(snapshot(context: context, candidates: ["second branch"]))
        _ = store.decision(
            for: makeContext(prefix: "Write sez"), backend: .remote, mutation: .append
        )

        let decision = store.decision(
            for: makeContext(prefix: "Write se"), backend: .remote, mutation: .delete
        )

        guard case .restoreRollback(let match) = decision else { return XCTFail("Expected rollback") }
        XCTAssertEqual(match.remainingText, "cond branch")
    }

    func testContextBackendSuffixSelectionAndScriptChangesInvalidate() {
        var store = makeStore()
        let context = makeContext(prefix: "Write ", suffix: "tail")
        store.record(snapshot(context: context, candidates: ["world text"]))

        XCTAssertEqual(store.decision(
            for: makeContext(prefix: "Write w", suffix: "tail"), backend: .localLlama, mutation: .append
        ), .mustRecompute(reason: .backendChanged))
        XCTAssertEqual(store.decision(
            for: makeContext(prefix: "Write w", suffix: "changed"), backend: .remote, mutation: .append
        ), .mustRecompute(reason: .suffixChanged))
        XCTAssertEqual(store.decision(
            for: makeContext(prefix: "Write w", suffix: "tail", selectedText: "x"),
            backend: .remote, mutation: .append
        ), .mustRecompute(reason: .selectionChanged))
        XCTAssertEqual(store.decision(
            for: makeContext(prefix: "Write 世", suffix: "tail"), backend: .remote, mutation: .append
        ), .mustRecompute(reason: .scriptChanged))
    }

    func testRemainderTTLBoundsDedupAndReset() {
        let start = Date(timeIntervalSince1970: 100)
        var store = SuggestionReuseStore(configuration: .init(
            maximumSnapshots: 2,
            maximumCandidates: 3,
            ttl: 2,
            minimumRemainingCharacters: 2
        ))
        for index in 0..<3 {
            let context = makeContext(prefix: "Base\(index) ", field: "field-\(index)")
            store.record(snapshot(
                context: context,
                candidates: ["alpha", "alpha", "beta"],
                createdAt: start.addingTimeInterval(Double(index) / 10)
            ), now: start)
        }
        XCTAssertLessThanOrEqual(store.snapshotCount, 2)
        XCTAssertLessThanOrEqual(store.candidateCount, 3)
        XCTAssertGreaterThan(store.evictionCount, 0)

        let shortContext = makeContext(prefix: "Base2 ", field: "field-2")
        XCTAssertEqual(store.decision(
            for: makeContext(prefix: "Base2 alph", field: "field-2"),
            backend: .remote,
            mutation: .append,
            now: start.addingTimeInterval(1)
        ), .mustRecompute(reason: .remainderTooShort))
        XCTAssertEqual(store.decision(
            for: shortContext,
            backend: .remote,
            mutation: .append,
            now: start.addingTimeInterval(5)
        ), .mustRecompute(reason: .expired))

        store.reset()
        XCTAssertEqual(store.snapshotCount, 0)
        XCTAssertEqual(store.candidateCount, 0)
    }

    func testKillSwitchPreventsRecordingAndReuse() {
        var store = SuggestionReuseStore(configuration: .init(enabled: false))
        let context = makeContext(prefix: "Write ")
        store.record(snapshot(context: context, candidates: ["candidate"]))
        XCTAssertEqual(store.snapshotCount, 0)
        XCTAssertEqual(store.decision(
            for: makeContext(prefix: "Write c"), backend: .remote, mutation: .append
        ), .mustRecompute(reason: .disabled))
        XCTAssertFalse(SuggestionReuseStore.Configuration.environmentDefault(
            environment: ["AUTOCOMP_DISABLE_SUGGESTION_REUSE": "1"]
        ).enabled)
    }

    private func makeStore() -> SuggestionReuseStore {
        SuggestionReuseStore(configuration: .init(minimumRemainingCharacters: 2))
    }

    private func snapshot(
        context: TextContext,
        candidates: [String],
        createdAt: Date = Date()
    ) -> SuggestionCandidateSnapshot {
        SuggestionCandidateSnapshot(
            context: context,
            backend: .remote,
            candidates: candidates.enumerated().map {
                SuggestionReusableCandidate(text: $0.element, originalRank: $0.offset)
            },
            createdAt: createdAt
        )
    }

    private func makeContext(
        prefix: String,
        field: String = "field",
        suffix: String? = nil,
        selectedText: String? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "test.app", displayName: "Test", processID: 1),
            focusedElementID: field,
            textBeforeCursor: prefix,
            textAfterCursor: suffix,
            selectedText: selectedText
        )
    }
}
