@testable import AutoCompApp
import Foundation
import XCTest

final class OnboardingWindowPolicyTests: XCTestCase {
    func testOnboardingUsesExplicitWizardStepState() throws {
        let source = try onboardingSource()

        XCTAssertTrue(source.contains("enum OnboardingWizardStep"))
        XCTAssertTrue(source.contains("@State private var selectedStep: OnboardingWizardStep = .welcome"))
        for requiredCase in [
            "case welcome",
            "case permissions",
            "case backend",
            "case privacy",
            "case shortcuts",
            "case tryIt",
            "case done"
        ] {
            XCTAssertTrue(source.contains(requiredCase), "Missing wizard step: \(requiredCase)")
        }
    }

    func testOnboardingKeepsFooterOutsideScrollableStepContent() throws {
        let source = try onboardingSource()

        XCTAssertTrue(source.contains("ScrollView"))
        XCTAssertTrue(source.contains("struct OnboardingWizardFooter: View"))
        XCTAssertTrue(source.contains("OnboardingWizardFooter("))
        XCTAssertTrue(source.contains("Button(\"Back\", action: goBack)"))
        XCTAssertTrue(source.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(source.contains(".frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 560)"))

        let scrollRange = try XCTUnwrap(source.range(of: "ScrollView"))
        let footerRange = try XCTUnwrap(source.range(of: "OnboardingWizardFooter("))
        XCTAssertLessThan(scrollRange.lowerBound, footerRange.lowerBound)
    }

    func testOnboardingProgressBackendSkipAndFinalActionsAreVisible() throws {
        let source = try onboardingSource()

        XCTAssertTrue(source.contains("ProgressView(value: step.progressFraction)"))
        XCTAssertTrue(source.contains("canSkipBackendSetup"))
        XCTAssertTrue(source.contains("Button(\"Skip Backend Setup\", action: skipBackend)"))
        XCTAssertTrue(source.contains("Button(\"Open Settings\", action: openSettings)"))
        XCTAssertTrue(source.contains("\"Start Using AutoComp\""))
        XCTAssertTrue(source.contains("finishWizard()"))
        XCTAssertTrue(source.contains("controller.closeOnboardingWindow()"))
        XCTAssertFalse(source.contains(".onDisappear"))
    }

    func testOnboardingWindowUsesExplicitBoundedContentSize() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AppController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onboardingWindowContentSize = NSSize(width: 560, height: 560)"))
        XCTAssertTrue(source.contains("onboardingWindowMinimumContentSize = NSSize(width: 520, height: 440)"))
        XCTAssertTrue(source.contains("onboardingWindowMaximumContentSize = NSSize(width: 680, height: 600)"))
        XCTAssertTrue(source.contains("maxSize: Self.onboardingWindowMaximumContentSize"))
        XCTAssertTrue(source.contains("window.contentMaxSize = maxSize"))
        XCTAssertTrue(source.contains("func closeOnboardingWindow()"))
        XCTAssertTrue(source.contains("existingWindow.isVisible"))
        XCTAssertTrue(source.contains("existingWindow.isMiniaturized"))
        XCTAssertTrue(source.contains("existingWindow.deminiaturize(nil)"))
        XCTAssertTrue(source.contains("onboardingWindow = nil"))
    }

    func testSwiftUIOnboardingSceneHasDefaultSize() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AutoCompApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".defaultSize(width: 560, height: 560)"))
    }

    private func onboardingSource() throws -> String {
        try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/OnboardingView.swift"),
            encoding: .utf8
        )
    }

}
