import AutoCompCore
import Foundation

@MainActor
final class InlineCommandCoordinator {
    var onStateChanged: ((Bool, InlineCommandKeyboardCapabilities) -> Void)?

    private let controllers: [any InlineCommandControlling]
    private let inputMethodStateProvider: () -> InputMethodState
    private let hostPublishDelayNanoseconds: UInt64
    private var activeKind: InlineCommandKind?
    private var isPipelineSuspended = false

    init(
        controllers: [any InlineCommandControlling],
        inputMethodStateProvider: @escaping () -> InputMethodState = { .asciiCompatible },
        hostPublishDelayNanoseconds: UInt64 = 0
    ) {
        self.controllers = controllers
        self.inputMethodStateProvider = inputMethodStateProvider
        self.hostPublishDelayNanoseconds = hostPublishDelayNanoseconds
        for controller in controllers {
            controller.onActiveChanged = { [weak self, weak controller] active in
                guard let self, let controller else { return }
                self.controllerStateChanged(controller, active: active)
            }
        }
    }

    var isActive: Bool { activeController != nil }
    var keyboardCapabilities: InlineCommandKeyboardCapabilities {
        activeController?.keyboardCapabilities ?? .inactive
    }
    var captureState: InlineCommandCaptureState? { activeController?.captureState }

    func handleInputEvent(_ event: CapturedInputEvent) async -> Bool {
        if isPipelineSuspended {
            let wasActive = isActive
            cancelAll(reason: .pipelineSuspended)
            return wasActive
        }
        guard inputMethodStateProvider().allowsAutomaticSuggestions else {
            let wasActive = isActive
            cancelAll(reason: .compositionActive)
            return wasActive
        }

        if case .text = event, hostPublishDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: hostPublishDelayNanoseconds)
        }

        if let activeController {
            let handled = await activeController.handleInputEvent(event)
            publishState()
            return handled
        }

        for controller in controllers {
            let handled = await controller.handleInputEvent(event)
            if controller.isActive {
                activeKind = controller.kind
                cancelAll(except: controller.kind, reason: .cancelled)
                publishState()
                return true
            }
            if handled { return true }
        }
        publishState()
        return false
    }

    func handleKeyboardCommand(_ command: InlineCommandKeyboardCommand) async {
        guard let activeController else { return }
        await activeController.handleKeyboardCommand(command)
        publishState()
    }

    func setPipelineSuspended(_ suspended: Bool) {
        isPipelineSuspended = suspended
        if suspended { cancelAll(reason: .pipelineSuspended) }
    }

    func cancelAll(reason: InlineCommandReason) {
        cancelAll(except: nil, reason: reason)
    }

    private var activeController: (any InlineCommandControlling)? {
        if let activeKind, let controller = controllers.first(where: { $0.kind == activeKind && $0.isActive }) {
            return controller
        }
        return controllers.first(where: \.isActive)
    }

    private func controllerStateChanged(_ controller: any InlineCommandControlling, active: Bool) {
        if active {
            activeKind = controller.kind
            cancelAll(except: controller.kind, reason: .cancelled)
        } else if activeKind == controller.kind {
            activeKind = nil
        }
        publishState()
    }

    private func cancelAll(except retainedKind: InlineCommandKind?, reason: InlineCommandReason) {
        for controller in controllers where controller.kind != retainedKind {
            controller.cancel(reason: reason)
        }
        if retainedKind == nil { activeKind = nil }
        publishState()
    }

    private func publishState() {
        onStateChanged?(isActive, keyboardCapabilities)
    }
}
