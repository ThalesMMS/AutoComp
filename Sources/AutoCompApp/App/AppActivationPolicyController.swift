import AppKit
import Foundation

@MainActor
protocol AppActivationPolicyApplying: AnyObject {
    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy)
    func activateIgnoringOtherApps()
}

@MainActor
final class AppActivationPolicyController {
    enum WindowID: String, Hashable {
        case settings
        case onboarding
        case health
        case debug
    }

    private let applier: any AppActivationPolicyApplying
    private var visibleWindowIDs: Set<WindowID> = []
    private(set) var currentPolicy: NSApplication.ActivationPolicy

    init(
        applier: any AppActivationPolicyApplying = NSApplicationActivationPolicyApplier(),
        initialPolicy: NSApplication.ActivationPolicy = .accessory
    ) {
        self.applier = applier
        self.currentPolicy = initialPolicy
    }

    var visibleWindowCount: Int {
        visibleWindowIDs.count
    }

    func contains(_ id: WindowID) -> Bool {
        visibleWindowIDs.contains(id)
    }

    func windowDidOpen(_ id: WindowID, activate: Bool = true) {
        let wasEmpty = visibleWindowIDs.isEmpty
        visibleWindowIDs.insert(id)

        if wasEmpty {
            apply(.regular)
        }
        if activate {
            applier.activateIgnoringOtherApps()
        }
    }

    func windowDidClose(_ id: WindowID) {
        guard visibleWindowIDs.remove(id) != nil else {
            return
        }

        if visibleWindowIDs.isEmpty {
            apply(.accessory)
        }
    }

    private func apply(_ policy: NSApplication.ActivationPolicy) {
        guard currentPolicy != policy else {
            return
        }
        currentPolicy = policy
        applier.setActivationPolicy(policy)
    }
}

@MainActor
private final class NSApplicationActivationPolicyApplier: AppActivationPolicyApplying {
    private weak var app: NSApplication?

    init(app: NSApplication = NSApp) {
        self.app = app
    }

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        app?.setActivationPolicy(policy)
    }

    func activateIgnoringOtherApps() {
        app?.activate(ignoringOtherApps: true)
    }
}
