import AutoCompCore
import Foundation

@MainActor
final class MacroCommandController: InlineCommandControlling {
    var onActiveChanged: ((Bool) -> Void)?

    let kind = InlineCommandKind.macro
    private let contextProvider: any TextContextProvider
    private let textReplacer: any InlineCommandTextReplacing
    private let preferencesStore: MacroPreferencesStore
    private let evaluator: any InlineCommandEvaluating
    private let panelController: any MacroPreviewPanelControlling
    private let hostPublishAwaiter: HostPublishAwaiter
    private let diagnostics: InlineCommandDiagnostics
    private let acceptKeyLabel: () -> String
    private let hostPublishDelayNanoseconds: UInt64
    private let timeoutNanoseconds: UInt64
    private var preferences: MacroPreferences
    private var triggerState = MacroTriggerStateMachine()
    private var currentValue: MacroValue?
    private var timeoutTask: Task<Void, Never>?

    init(
        contextProvider: any TextContextProvider,
        textReplacer: any InlineCommandTextReplacing,
        preferencesStore: MacroPreferencesStore = MacroPreferencesStore(),
        evaluator: any InlineCommandEvaluating = LocalMacroEvaluator(),
        panelController: any MacroPreviewPanelControlling = MacroPreviewPanelController(),
        hostPublishAwaiter: HostPublishAwaiter = HostPublishAwaiter(),
        diagnostics: InlineCommandDiagnostics = InlineCommandDiagnostics(),
        acceptKeyLabel: @escaping () -> String = { "Tab" },
        hostPublishDelayNanoseconds: UInt64 = 25_000_000,
        timeoutNanoseconds: UInt64 = 8_000_000_000
    ) {
        self.contextProvider = contextProvider
        self.textReplacer = textReplacer
        self.preferencesStore = preferencesStore
        self.evaluator = evaluator
        self.panelController = panelController
        self.hostPublishAwaiter = hostPublishAwaiter
        self.diagnostics = diagnostics
        self.acceptKeyLabel = acceptKeyLabel
        self.hostPublishDelayNanoseconds = hostPublishDelayNanoseconds
        self.timeoutNanoseconds = timeoutNanoseconds
        self.preferences = preferencesStore.load()
    }

    var isActive: Bool { triggerState.activeRun != nil }
    var activeQuery: String? { triggerState.activeRun?.query }
    var captureState: InlineCommandCaptureState? {
        guard let run = triggerState.activeRun else { return nil }
        return InlineCommandCaptureState(
            kind: kind,
            queryUTF16Length: run.query.utf16.count,
            stableFieldIdentity: run.stableFieldIdentity
        )
    }
    var keyboardCapabilities: InlineCommandKeyboardCapabilities {
        isActive && currentValue != nil ? .singleResult : .inactive
    }

    func updatePreferences(_ preferences: MacroPreferences) {
        self.preferences = preferences
        if !preferences.isEnabled { cancel(reason: .cancelled) }
    }

    func handleInputEvent(_ event: CapturedInputEvent) async -> Bool {
        guard preferences.isEnabled else {
            cancel(reason: .cancelled)
            return false
        }
        switch event {
        case .pointer, .shortcutMutation, .navigation:
            let wasActive = isActive
            cancel(reason: .cancelled)
            return wasActive
        case .dismissal:
            let wasActive = isActive
            cancel(reason: .cancelled)
            return wasActive
        case .tab, .acceptAll:
            guard currentValue != nil else { return false }
            await commit()
            return true
        case .text(let keyCode, _):
            if keyCode == 36 || keyCode == 76 {
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
        guard isActive else { return }
        switch command {
        case .acceptSelected:
            if currentValue != nil { await commit() }
        case .cancel, .selectPrevious, .selectNext:
            cancel(reason: .cancelled)
        }
    }

    func cancel(reason: InlineCommandReason) {
        let wasActive = isActive
        let queryUTF16Length = triggerState.activeRun?.query.utf16.count
        triggerState.cancel()
        currentValue = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        panelController.hide()
        if wasActive {
            diagnostics.record(kind: kind, reason: reason, queryUTF16Length: queryUTF16Length)
        }
        if wasActive { onActiveChanged?(false) }
    }

    private func refreshFromCurrentContext() async -> Bool {
        let wasActive = isActive
        do {
            let context = try await contextProvider.currentContext()
            if let identity = triggerState.activeRun?.stableFieldIdentity,
               context.stableFieldIdentity != identity {
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

            diagnostics.record(
                kind: kind,
                reason: wasActive ? .updated : .opened,
                queryUTF16Length: run.query.utf16.count
            )
            switch evaluator.evaluate(run.query) {
            case .value(let value):
                currentValue = value
                panelController.show(
                    value: value,
                    anchorContext: context,
                    acceptKeyLabel: acceptKeyLabel(),
                    onCommit: { [weak self] in
                        Task { @MainActor in await self?.commit() }
                    }
                )
            case .failure:
                currentValue = nil
                panelController.hide()
                diagnostics.record(
                    kind: kind,
                    reason: .unsupported,
                    queryUTF16Length: run.query.utf16.count
                )
            }
            armTimeout()
            if !wasActive { onActiveChanged?(true) }
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

    private func commit() async {
        guard let run = triggerState.activeRun, let value = currentValue else {
            cancel(reason: .unsupported)
            return
        }
        do {
            let baseline = try await contextProvider.currentContext()
            let plan = InlineCommandReplacementPlan(
                expectedLiteral: run.literal,
                replacementText: value.insertionText,
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
                reason: "inline-command-macro-commit"
            )
            cancel(reason: .committed)
        } catch {
            cancel(reason: .staleTarget)
        }
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        guard timeoutNanoseconds > 0 else { return }
        let timeoutNanoseconds = self.timeoutNanoseconds
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.cancel(reason: .cancelled)
        }
    }
}
