@testable import AutoCompApp
import Foundation
import XCTest

@MainActor
final class PermissionGuidanceTests: XCTestCase {
    func testPermissionMetadataDeclaresGuidanceStylesAndFallbackCopy() {
        XCTAssertEqual(PermissionKind.accessibility.guidanceStyle, .guidedOverlay)
        XCTAssertEqual(PermissionKind.inputMonitoring.guidanceStyle, .guidedOverlay)
        XCTAssertEqual(PermissionKind.screenRecording.guidanceStyle, .settingsOnly)

        for kind in PermissionKind.allCases {
            let presentation = PermissionPresentationFactory.presentation(
                for: kind,
                state: missingState()
            )
            XCTAssertEqual(presentation.guidanceStyle, kind.guidanceStyle)
            XCTAssertFalse(presentation.guidanceActionTitle.isEmpty)
            XCTAssertTrue(presentation.guidanceFallbackText.contains(kind.settingsLocation))
        }
    }

    func testGuidanceRequestsPermissionOpensSettingsAndShowsAnchoredOverlay() {
        let service = FakePermissionStatusProvider()
        let locator = FakeSystemSettingsWindowLocator(window: SystemSettingsWindow(
            ownerPID: 42,
            title: "Privacy & Security",
            frame: CGRect(x: 120, y: 180, width: 900, height: 700)
        ))
        let overlay = FakePermissionOverlayPresenter()
        let controller = PermissionGuidanceController(
            permissionService: service,
            locator: locator,
            overlayPresenter: overlay,
            hostApp: testHostApp()
        )

        controller.begin(for: .accessibility)

        XCTAssertEqual(service.requestedKinds, [.accessibility])
        XCTAssertEqual(service.openedSettingsKinds, [.accessibility])
        XCTAssertEqual(service.refreshCount, 1)
        XCTAssertEqual(overlay.shown.count, 1)
        XCTAssertEqual(overlay.shown.first?.flow.kind, .accessibility)
        XCTAssertEqual(overlay.shown.first?.anchorFrame, locator.window?.frame)
        XCTAssertTrue(controller.activeFlow?.didFindSystemSettingsWindow == true)
    }

    func testSettingsOnlyGuidanceOpensSettingsWithoutOverlay() {
        let service = FakePermissionStatusProvider()
        let overlay = FakePermissionOverlayPresenter()
        let controller = PermissionGuidanceController(
            permissionService: service,
            locator: FakeSystemSettingsWindowLocator(window: SystemSettingsWindow(
                ownerPID: 42,
                title: "Privacy & Security",
                frame: CGRect(x: 120, y: 180, width: 900, height: 700)
            )),
            overlayPresenter: overlay,
            hostApp: testHostApp()
        )

        controller.begin(for: .screenRecording)

        XCTAssertEqual(service.requestedKinds, [.screenRecording])
        XCTAssertEqual(service.openedSettingsKinds, [.screenRecording])
        XCTAssertNil(controller.activeFlow)
        XCTAssertTrue(overlay.shown.isEmpty)
        XCTAssertEqual(overlay.closeCount, 0)
    }

    func testGuidanceFallsBackWhenSystemSettingsWindowCannotBeLocated() {
        let service = FakePermissionStatusProvider()
        let overlay = FakePermissionOverlayPresenter()
        let controller = PermissionGuidanceController(
            permissionService: service,
            locator: FakeSystemSettingsWindowLocator(window: nil),
            overlayPresenter: overlay,
            hostApp: testHostApp()
        )

        controller.begin(for: .inputMonitoring)
        controller.refreshGuidanceState()
        controller.refreshGuidanceState()
        controller.refreshGuidanceState()

        XCTAssertEqual(overlay.shown.last?.flow.kind, .inputMonitoring)
        XCTAssertNil(overlay.shown.last?.anchorFrame)
        XCTAssertTrue(overlay.shown.last?.flow.fallbackText.contains("System Settings was not found in time") == true)
        XCTAssertEqual(overlay.closeCount, 0)
    }

    func testGuidanceClosesWhenPermissionBecomesGranted() {
        let service = FakePermissionStatusProvider()
        let overlay = FakePermissionOverlayPresenter()
        let controller = PermissionGuidanceController(
            permissionService: service,
            locator: FakeSystemSettingsWindowLocator(window: SystemSettingsWindow(
                ownerPID: 42,
                title: "Privacy & Security",
                frame: CGRect(x: 120, y: 180, width: 900, height: 700)
            )),
            overlayPresenter: overlay,
            hostApp: testHostApp()
        )

        controller.begin(for: .accessibility)
        service.enabledKinds.insert(.accessibility)
        controller.refreshGuidanceState()

        XCTAssertNil(controller.activeFlow)
        XCTAssertEqual(overlay.closeCount, 1)
    }

    func testGuidanceClosesWhenSystemSettingsDisappearsAfterBeingLocated() {
        let service = FakePermissionStatusProvider()
        let locator = FakeSystemSettingsWindowLocator(window: SystemSettingsWindow(
            ownerPID: 42,
            title: "Privacy & Security",
            frame: CGRect(x: 120, y: 180, width: 900, height: 700)
        ))
        let overlay = FakePermissionOverlayPresenter()
        let controller = PermissionGuidanceController(
            permissionService: service,
            locator: locator,
            overlayPresenter: overlay,
            hostApp: testHostApp()
        )

        controller.begin(for: .accessibility)
        locator.window = nil
        controller.refreshGuidanceState()

        XCTAssertNil(controller.activeFlow)
        XCTAssertEqual(overlay.closeCount, 1)
    }

    func testOverlayWindowDeclaresNonActivatingNoFocusContract() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Services/Permission/Guidance/PermissionOverlayWindowController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".nonactivatingPanel"))
        XCTAssertTrue(source.contains("override var canBecomeKey: Bool { false }"))
        XCTAssertTrue(source.contains("override var canBecomeMain: Bool { false }"))
        XCTAssertTrue(source.contains("orderFrontRegardless()"))
        XCTAssertTrue(source.contains("struct PermissionDragSourceView: NSViewRepresentable"))
        XCTAssertTrue(source.contains("final class PermissionDragSourceAppKitView: NSView, NSDraggingSource"))
        XCTAssertTrue(source.contains("NSDraggingItem(pasteboardWriter: permissionTargetURL as NSURL)"))
        XCTAssertTrue(source.contains("beginDraggingSession(with: [draggingItem], event: event, source: self)"))
        XCTAssertTrue(source.contains("NSWorkspace.shared.icon(forFile:"))
        XCTAssertFalse(source.contains(".onDrag"))
    }

    func testPermissionHostAppDoesNotOfferExecutableForSwiftPMDebugRuns() {
        let hostApp = PermissionHostApp(
            displayName: "AutoComp",
            bundleID: "unknown",
            executablePath: "/Users/test/GitHub/AutoComp/.build/debug/AutoComp",
            bundleURL: URL(fileURLWithPath: "/Users/test/GitHub/AutoComp/.build/debug", isDirectory: true)
        )

        XCTAssertNil(hostApp.bundleURL)
        XCTAssertNil(hostApp.permissionTargetURL)
        XCTAssertEqual(hostApp.identityDetail, "AutoComp.app bundle not found")
    }

    func testPermissionHostAppOffersStagedAppForSwiftPMDebugRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompPermissionHost-\(UUID().uuidString)", isDirectory: true)
        let buildDirectory = root
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
        let stagedApp = root
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("AutoComp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: buildDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let hostApp = PermissionHostApp(
            displayName: "AutoComp",
            bundleID: "unknown",
            executablePath: buildDirectory.appendingPathComponent("AutoComp").path,
            bundleURL: buildDirectory
        )

        let expectedPath = stagedApp.standardizedFileURL.path
        XCTAssertEqual(hostApp.bundleURL?.path, expectedPath)
        XCTAssertEqual(hostApp.permissionTargetURL?.path, expectedPath)
        XCTAssertEqual(hostApp.identityDetail, expectedPath)
    }

    func testPermissionHostAppOffersRepoStagedAppForDerivedDataDebugRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompPermissionHost-\(UUID().uuidString)", isDirectory: true)
        let derivedDataBuildDirectory = root
            .appendingPathComponent("DerivedData", isDirectory: true)
            .appendingPathComponent("AutoComp-random", isDirectory: true)
            .appendingPathComponent("Build", isDirectory: true)
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Debug", isDirectory: true)
        let checkoutRoot = root
            .appendingPathComponent("AutoComp", isDirectory: true)
        let stagedApp = checkoutRoot
            .appendingPathComponent("AutoComp", isDirectory: true)
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("AutoComp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: derivedDataBuildDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagedApp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let hostApp = PermissionHostApp(
            displayName: "AutoComp",
            bundleID: "unknown",
            executablePath: derivedDataBuildDirectory.appendingPathComponent("AutoComp").path,
            bundleURL: derivedDataBuildDirectory,
            searchBaseURLs: [checkoutRoot]
        )

        let expectedPath = stagedApp.standardizedFileURL.path
        XCTAssertEqual(hostApp.bundleURL?.path, expectedPath)
        XCTAssertEqual(hostApp.permissionTargetURL?.path, expectedPath)
        XCTAssertEqual(hostApp.identityDetail, expectedPath)
    }

    func testPermissionHostAppUsesBundleForRealAppRuns() {
        let hostApp = PermissionHostApp(
            displayName: "AutoComp",
            bundleID: "com.autocomp.AutoComp",
            executablePath: "/Applications/AutoComp.app/Contents/MacOS/AutoComp",
            bundleURL: URL(fileURLWithPath: "/Applications/AutoComp.app", isDirectory: true)
        )

        XCTAssertEqual(hostApp.bundleURL?.path, "/Applications/AutoComp.app")
        XCTAssertEqual(hostApp.permissionTargetURL?.path, "/Applications/AutoComp.app")
        XCTAssertEqual(hostApp.identityDetail, "com.autocomp.AutoComp")
    }

    func testPermissionHostAppDerivesBundleFromExecutableInsideAppBundle() {
        let hostApp = PermissionHostApp(
            displayName: "AutoComp",
            bundleID: "unknown",
            executablePath: "/Users/test/GitHub/AutoComp/dist/AutoComp.app/Contents/MacOS/AutoComp",
            bundleURL: URL(fileURLWithPath: "/Users/test/GitHub/AutoComp/dist/AutoComp.app/Contents/MacOS", isDirectory: true)
        )

        XCTAssertEqual(hostApp.bundleURL?.path, "/Users/test/GitHub/AutoComp/dist/AutoComp.app")
        XCTAssertEqual(hostApp.permissionTargetURL?.path, "/Users/test/GitHub/AutoComp/dist/AutoComp.app")
        XCTAssertEqual(hostApp.identityDetail, "/Users/test/GitHub/AutoComp/dist/AutoComp.app")
    }

    func testGuidedInputMonitoringCopyKeepsDragFallbackVisible() {
        XCTAssertTrue(PermissionKind.inputMonitoring.guidanceActionTitle.contains("drag AutoComp"))
        XCTAssertTrue(PermissionKind.inputMonitoring.guidanceFallbackText.contains("drag AutoComp"))
    }

    func testOnboardingSettingsAndHealthUseGuidanceController() throws {
        let root = try packageRoot()
        let appController = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/App/AppController.swift"),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/OnboardingView.swift"),
            encoding: .utf8
        )
        let setup = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/Settings/Sections/SetupSettingsView.swift"),
            encoding: .utf8
        )
        let health = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/HealthDashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(onboarding.contains("controller.startPermissionGuidance(for: kind)"))
        XCTAssertTrue(setup.contains("controller.startPermissionGuidance(for: permission.kind)"))
        XCTAssertTrue(setup.contains("@EnvironmentObject private var installationLocation"))
        XCTAssertTrue(setup.contains("Section(\"Install location\")"))
        XCTAssertTrue(health.contains("controller.startPermissionGuidance(for: kind)"))
        XCTAssertTrue(health.contains("permissionKind(forSystemSettingsActionID"))
        XCTAssertTrue(appController.contains("NSWindow.willCloseNotification"))
        XCTAssertTrue(appController.contains("cancelPermissionGuidance()"))
        XCTAssertTrue(appController.contains("window === onboardingWindow"))
        XCTAssertTrue(appController.contains("window === settingsWindow"))
    }

    private func testHostApp() -> PermissionHostApp {
        PermissionHostApp(
            displayName: "AutoComp",
            bundleID: "com.autocomp.AutoComp",
            executablePath: "/Applications/AutoComp.app/Contents/MacOS/AutoComp",
            bundleURL: URL(fileURLWithPath: "/Applications/AutoComp.app")
        )
    }

    private func missingState() -> PermissionStateSnapshot {
        PermissionStateSnapshot(
            accessibilityTrusted: false,
            inputMonitoringAllowed: false,
            inputMonitoringStatus: PermissionKind.inputMonitoring.baselineDescription,
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
        )
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }
}

@MainActor
private final class FakePermissionStatusProvider: PermissionStatusProviding {
    var enabledKinds: Set<PermissionKind> = []
    var requestedKinds: [PermissionKind] = []
    var openedSettingsKinds: [PermissionKind] = []
    var refreshCount = 0

    func presentation(for kind: PermissionKind) -> PermissionPresentation {
        PermissionPresentationFactory.presentation(for: kind, state: state(for: kind))
    }

    func request(_ kind: PermissionKind) {
        requestedKinds.append(kind)
    }

    func openSettings(for kind: PermissionKind) {
        openedSettingsKinds.append(kind)
    }

    func refresh() {
        refreshCount += 1
    }

    private func state(for kind: PermissionKind) -> PermissionStateSnapshot {
        PermissionStateSnapshot(
            accessibilityTrusted: enabledKinds.contains(.accessibility),
            inputMonitoringAllowed: enabledKinds.contains(.inputMonitoring),
            inputMonitoringStatus: PermissionKind.inputMonitoring.baselineDescription,
            screenRecordingAllowed: enabledKinds.contains(.screenRecording),
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
        )
    }
}

private final class FakeSystemSettingsWindowLocator: SystemSettingsWindowLocating {
    var window: SystemSettingsWindow?

    init(window: SystemSettingsWindow?) {
        self.window = window
    }

    func locateSystemSettingsWindow() -> SystemSettingsWindow? {
        window
    }
}

@MainActor
private final class FakePermissionOverlayPresenter: PermissionOverlayPresenting {
    struct Shown {
        let flow: PermissionGuidanceFlow
        let anchorFrame: CGRect?
    }

    var shown: [Shown] = []
    var closeCount = 0

    func show(flow: PermissionGuidanceFlow, anchorFrame: CGRect?) {
        shown.append(Shown(flow: flow, anchorFrame: anchorFrame))
    }

    func close() {
        closeCount += 1
    }
}
