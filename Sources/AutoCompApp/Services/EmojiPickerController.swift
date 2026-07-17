import AutoCompCore
import Foundation

@MainActor
protocol InlineCommandTextReplacing: AnyObject {
    func replaceTrailingText(utf16Length: Int, with text: String) throws
}

typealias EmojiTextReplacing = InlineCommandTextReplacing

@MainActor
protocol EmojiPickerPanelControlling: AnyObject {
    func show(
        matches: [EmojiMatch],
        selectedIndex: Int,
        preferences: EmojiVariantPreferences,
        anchorContext: TextContext,
        onSelect: @escaping (Int) -> Void
    )
    func hide()
}

@MainActor
final class EmojiPickerController: InlineCommandControlling {
    var onActiveChanged: ((Bool) -> Void)?

    let kind = InlineCommandKind.emoji

    private let contextProvider: any TextContextProvider
    private let textReplacer: any EmojiTextReplacing
    private let preferencesStore: EmojiVariantPreferencesStore
    private let matcher: EmojiMatcher
    private let panelController: any EmojiPickerPanelControlling
    private let hostPublishAwaiter: HostPublishAwaiter
    private let diagnostics: InlineCommandDiagnostics
    private let hostPublishDelayNanoseconds: UInt64
    private var triggerState = EmojiTriggerStateMachine()
    private var matches: [EmojiMatch] = []
    private var selectedIndex = 0
    private var preferences: EmojiVariantPreferences

    init(
        contextProvider: any TextContextProvider,
        textReplacer: any EmojiTextReplacing,
        preferencesStore: EmojiVariantPreferencesStore = EmojiVariantPreferencesStore(),
        matcher: EmojiMatcher = EmojiMatcher(),
        panelController: any EmojiPickerPanelControlling = EmojiPickerPanelController(),
        hostPublishAwaiter: HostPublishAwaiter = HostPublishAwaiter(),
        diagnostics: InlineCommandDiagnostics = InlineCommandDiagnostics(),
        hostPublishDelayNanoseconds: UInt64 = 25_000_000
    ) {
        self.contextProvider = contextProvider
        self.textReplacer = textReplacer
        self.preferencesStore = preferencesStore
        self.matcher = matcher
        self.panelController = panelController
        self.hostPublishAwaiter = hostPublishAwaiter
        self.diagnostics = diagnostics
        self.hostPublishDelayNanoseconds = hostPublishDelayNanoseconds
        self.preferences = preferencesStore.load()
    }

    var isActive: Bool {
        triggerState.activeRun != nil
    }

    var activeQuery: String? {
        triggerState.activeRun?.query
    }

    var captureState: InlineCommandCaptureState? {
        guard let run = triggerState.activeRun else { return nil }
        return InlineCommandCaptureState(
            kind: kind,
            queryUTF16Length: run.query.utf16.count,
            stableFieldIdentity: run.stableFieldIdentity
        )
    }

    var keyboardCapabilities: InlineCommandKeyboardCapabilities {
        isActive && !matches.isEmpty ? .selectableResults : .inactive
    }

    func updatePreferences(_ preferences: EmojiVariantPreferences) {
        self.preferences = preferences
        if !preferences.isEnabled {
            cancel(reason: .cancelled)
        }
    }

    func reloadPreferences() {
        updatePreferences(preferencesStore.load())
    }

    func handleInputEvent(_ event: CapturedInputEvent) async -> Bool {
        guard preferences.isEnabled else {
            cancel(reason: .cancelled)
            return false
        }

        switch event {
        case .pointer, .shortcutMutation:
            let wasActive = isActive
            cancel(reason: .cancelled)
            return wasActive
        case .dismissal:
            let wasActive = isActive
            cancel(reason: .cancelled)
            return wasActive
        case .navigation:
            guard isActive else {
                return false
            }
            // While the picker is open, arrow keys belong to the picker. The
            // keyboard service maps supported arrows to EmojiKeyboardCommand;
            // swallowing other navigation prevents caret movement mid-query.
            return true
        case .tab, .acceptAll:
            guard isActive else {
                return false
            }
            await commitSelected()
            return true
        case .text:
            if case .text(let keyCode, _) = event,
               keyCode == 36 || keyCode == 76 {
                let wasActive = isActive
                cancel(reason: .cancelled)
                return wasActive
            }
            if hostPublishDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: hostPublishDelayNanoseconds)
            }
            return await refreshFromCurrentContext()
        }
    }

    func handleKeyboardCommand(_ command: InlineCommandKeyboardCommand) async {
        guard isActive else {
            return
        }

        switch command {
        case .acceptSelected:
            await commitSelected()
        case .cancel:
            cancel(reason: .cancelled)
        case .selectPrevious:
            select(offset: -1)
        case .selectNext:
            select(offset: 1)
        }
    }

    private func refreshFromCurrentContext() async -> Bool {
        let wasActive = isActive
        do {
            let context = try await contextProvider.currentContext()
            guard focusMatches(context) else {
                cancel(reason: .staleTarget)
                return wasActive
            }

            guard let run = triggerState.update(
                textBeforeCursor: context.textBeforeCursor,
                stableFieldIdentity: context.stableFieldIdentity
            ) else {
                cancel(reason: .cancelled)
                return wasActive
            }

            let nextMatches = matcher.matches(for: run.query)
            guard !nextMatches.isEmpty else {
                cancel(reason: .unsupported)
                return wasActive
            }

            matches = nextMatches
            selectedIndex = min(selectedIndex, max(0, nextMatches.count - 1))

            if run.hasClosingColon,
               let exactMatch = matcher.exactMatch(for: run.query) {
                matches = [exactMatch]
                selectedIndex = 0
                await commitSelected()
                return true
            }

            panelController.show(
                matches: matches,
                selectedIndex: selectedIndex,
                preferences: preferences,
                anchorContext: context,
                onSelect: { [weak self] index in
                    Task { @MainActor in
                        self?.selectedIndex = index
                        await self?.commitSelected()
                    }
                }
            )
            diagnostics.record(
                kind: kind,
                reason: wasActive ? .updated : .opened,
                queryUTF16Length: run.query.utf16.count
            )
            notifyActiveChangedIfNeeded(wasActive: wasActive)
            return true
        } catch let error as AXTextContextError {
            if error == .secureOrUnsupportedField, !wasActive {
                diagnostics.record(kind: kind, reason: .secureField)
            }
            cancel(reason: error == .secureOrUnsupportedField ? .secureField : .cancelled)
            return wasActive
        } catch {
            cancel(reason: .cancelled)
            return wasActive
        }
    }

    private func focusMatches(_ context: TextContext) -> Bool {
        guard let activeIdentity = triggerState.activeRun?.stableFieldIdentity,
              let nextIdentity = context.stableFieldIdentity else {
            return true
        }

        return activeIdentity == nextIdentity
    }

    private func select(offset: Int) {
        guard !matches.isEmpty else {
            return
        }

        selectedIndex = (selectedIndex + offset + matches.count) % matches.count
        Task { @MainActor in
            if let context = try? await contextProvider.currentContext() {
                panelController.show(
                    matches: matches,
                    selectedIndex: selectedIndex,
                    preferences: preferences,
                    anchorContext: context,
                    onSelect: { [weak self] index in
                        Task { @MainActor in
                            self?.selectedIndex = index
                            await self?.commitSelected()
                        }
                    }
                )
            }
        }
    }

    private func commitSelected() async {
        guard let run = triggerState.activeRun,
              matches.indices.contains(selectedIndex) else {
            cancel(reason: .unsupported)
            return
        }

        let match = matches[selectedIndex]
        do {
            let baseline = try await contextProvider.currentContext()
            let plan = InlineCommandReplacementPlan(
                expectedLiteral: run.literal,
                replacementText: preferences.glyph(for: match.entry),
                stableFieldIdentity: run.stableFieldIdentity
            )
            guard plan.validates(baseline) else {
                cancel(reason: .staleTarget)
                return
            }
            try textReplacer.replaceTrailingText(
                utf16Length: plan.replacementUTF16Length,
                with: plan.replacementText
            )
            panelController.hide()
            _ = await hostPublishAwaiter.awaitPublication(
                after: baseline,
                provider: contextProvider,
                reason: "inline-command-emoji-commit"
            )
            cancel(reason: .committed)
        } catch {
            GeometryDebug.log("emoji-picker commit-failed reason=\(error.localizedDescription)")
            cancel(reason: .staleTarget)
        }
    }

    func cancel(reason: InlineCommandReason) {
        let wasActive = isActive
        let queryUTF16Length = triggerState.activeRun?.query.utf16.count
        triggerState.cancel()
        matches = []
        selectedIndex = 0
        panelController.hide()
        if wasActive {
            diagnostics.record(kind: kind, reason: reason, queryUTF16Length: queryUTF16Length)
        }
        notifyActiveChangedIfNeeded(wasActive: wasActive)
    }

    private func notifyActiveChangedIfNeeded(wasActive: Bool) {
        guard wasActive != isActive else {
            return
        }
        onActiveChanged?(isActive)
    }
}

extension AcceptanceService: InlineCommandTextReplacing {
    func replaceTrailingText(utf16Length: Int, with text: String) throws {
        guard utf16Length >= 0 else {
            throw AcceptanceError.insertionFailed
        }

        for _ in 0..<utf16Length {
            try pressDeleteBackward()
        }
        try insert(text)
    }
}
