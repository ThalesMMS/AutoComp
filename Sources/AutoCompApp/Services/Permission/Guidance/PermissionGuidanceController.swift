import AppKit
import Combine
import Foundation

@MainActor
protocol PermissionStatusProviding: AnyObject {
    func presentation(for kind: PermissionKind) -> PermissionPresentation
    func request(_ kind: PermissionKind)
    func openSettings(for kind: PermissionKind)
    func refresh()
}

extension PermissionService: PermissionStatusProviding {}

struct PermissionGuidanceFlow: Equatable {
    let kind: PermissionKind
    let style: PermissionGuidanceStyle
    let hostApp: PermissionHostApp
    var fallbackText: String
    var didFindSystemSettingsWindow: Bool
}

@MainActor
final class PermissionGuidanceController: ObservableObject {
    @Published private(set) var activeFlow: PermissionGuidanceFlow?

    private let permissionService: PermissionStatusProviding
    private let locator: SystemSettingsWindowLocating
    private let overlayPresenter: PermissionOverlayPresenting
    private let hostApp: PermissionHostApp
    private nonisolated(unsafe) var refreshTimer: Timer?
    private var locationAttempts = 0

    init(
        permissionService: PermissionStatusProviding,
        locator: SystemSettingsWindowLocating = SystemSettingsWindowLocator(),
        overlayPresenter: PermissionOverlayPresenting? = nil,
        hostApp: PermissionHostApp = .current()
    ) {
        self.permissionService = permissionService
        self.locator = locator
        self.hostApp = hostApp
        if let overlayPresenter {
            self.overlayPresenter = overlayPresenter
        } else {
            self.overlayPresenter = PermissionOverlayWindowController(onCancel: {})
        }
    }

    convenience init(permissionService: PermissionStatusProviding, hostApp: PermissionHostApp = .current()) {
        let controllerBox = PermissionGuidanceControllerBox()
        let overlay = PermissionOverlayWindowController {
            controllerBox.controller?.cancel()
        }
        self.init(
            permissionService: permissionService,
            locator: SystemSettingsWindowLocator(),
            overlayPresenter: overlay,
            hostApp: hostApp
        )
        controllerBox.controller = self
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func begin(for kind: PermissionKind) {
        cancel()

        let presentation = permissionService.presentation(for: kind)
        guard !presentation.isComplete else {
            return
        }

        permissionService.request(kind)
        let currentPresentation = permissionService.presentation(for: kind)
        guard !currentPresentation.isComplete else {
            return
        }

        permissionService.openSettings(for: kind)
        guard currentPresentation.guidanceStyle == .guidedOverlay else {
            return
        }

        activeFlow = PermissionGuidanceFlow(
            kind: kind,
            style: currentPresentation.guidanceStyle,
            hostApp: hostApp,
            fallbackText: currentPresentation.guidanceFallbackText,
            didFindSystemSettingsWindow: false
        )

        locationAttempts = 0
        refreshGuidanceState()
        guard activeFlow != nil else {
            return
        }
        startRefreshTimer()
    }

    func cancel() {
        let shouldCloseOverlay = activeFlow != nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        if shouldCloseOverlay {
            overlayPresenter.close()
        }
        activeFlow = nil
        locationAttempts = 0
    }

    func refreshGuidanceState() {
        guard var flow = activeFlow else {
            return
        }

        permissionService.refresh()
        if permissionService.presentation(for: flow.kind).isComplete {
            cancel()
            return
        }

        let settingsWindow = locator.locateSystemSettingsWindow()
        if let settingsWindow {
            flow.didFindSystemSettingsWindow = true
            activeFlow = flow
            overlayPresenter.show(flow: flow, anchorFrame: settingsWindow.frame)
            return
        }

        locationAttempts += 1
        if flow.didFindSystemSettingsWindow {
            cancel()
            return
        }

        let fallbackFlow = PermissionGuidanceFlow(
            kind: flow.kind,
            style: flow.style,
            hostApp: flow.hostApp,
            fallbackText: fallbackText(for: flow.kind, attempts: locationAttempts),
            didFindSystemSettingsWindow: false
        )
        activeFlow = fallbackFlow
        overlayPresenter.show(flow: fallbackFlow, anchorFrame: nil)
    }

    private func fallbackText(for kind: PermissionKind, attempts: Int) -> String {
        if attempts < 4 {
            return "Opening System Settings. \(kind.guidanceFallbackText)"
        }
        return "System Settings was not found in time. \(kind.guidanceFallbackText)"
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshGuidanceState()
            }
        }
    }
}

private final class PermissionGuidanceControllerBox {
    weak var controller: PermissionGuidanceController?
}
