import XCTest

final class MenuBarContentViewRedesignTests: XCTestCase {
    func testMenuBarUsesCompactOperationalSurface() throws {
        let source = try menuBarSource()

        XCTAssertTrue(source.contains("struct MenuHeader"))
        XCTAssertTrue(source.contains("struct MenuPrimaryActions"))
        XCTAssertTrue(source.contains("struct MenuCompactSummarySection"))
        XCTAssertTrue(source.contains("MenuSummaryRow(title: \"Backend\""))
        XCTAssertTrue(source.contains("MenuSummaryRow(title: \"Permissions\""))
        XCTAssertTrue(source.contains("MenuSummaryRow(title: \"Focused app\""))
        XCTAssertTrue(source.contains("Button(\"View details...\", action: openDetails)"))
        XCTAssertTrue(source.contains(".frame(width: 300)"))
        XCTAssertFalse(source.contains("ScrollView"))
    }

    func testPrimaryActionsStayVisibleAndRouteToSettingsHealthAndSetup() throws {
        let source = try menuBarSource()
        let actionsRange = try XCTUnwrap(source.range(of: "MenuPrimaryActions("))
        let warningRange = try XCTUnwrap(source.range(of: "if installationLocation.status.shouldWarn"))

        XCTAssertLessThan(
            source.distance(from: source.startIndex, to: actionsRange.lowerBound),
            source.distance(from: source.startIndex, to: warningRange.lowerBound)
        )
        XCTAssertTrue(source.contains("Label(\"Open Settings...\""))
        XCTAssertTrue(source.contains("Label(\"Run Setup...\""))
        XCTAssertTrue(source.contains("Label(\"Health Dashboard\""))
        XCTAssertTrue(source.contains("Label(\"Check for Updates...\""))
        XCTAssertTrue(source.contains("controller.showSettingsWindow()"))
        XCTAssertTrue(source.contains("controller.showOnboardingWindow()"))
        XCTAssertTrue(source.contains("controller.selectedSettingsSection = .health"))
    }

    func testMenuDoesNotRenderLongDiagnosticsByDefault() throws {
        let source = try menuBarSource()

        XCTAssertFalse(source.contains("engine.statusMessage"))
        XCTAssertFalse(source.contains("MenuStatusSnapshot.make"))
        XCTAssertFalse(source.contains("MenuStatusSection"))
        XCTAssertFalse(source.contains("ForEach(engine.diagnostics.menuRows)"))
        XCTAssertFalse(source.contains("Label(\"Diagnostics\""))
    }

    func testStatusDotHasOperationalAccessibilityLabel() throws {
        let source = try menuBarSource()

        XCTAssertTrue(source.contains("StatusDot(state: state, label: accessibilityLabel)"))
        XCTAssertTrue(source.contains("private var menuStatusAccessibilityLabel: String"))
        XCTAssertTrue(source.contains("\"\\(menuStatusTitle). \\(menuStatusSubtitle)\""))
    }

    func testDetailedRuntimeDiagnosticsRemainAvailableInDeveloperSettings() throws {
        let developerSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/Settings/Sections/DeveloperSettingsView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(developerSource.contains("Section(\"Runtime diagnostics\")"))
        XCTAssertTrue(developerSource.contains("ForEach(engine.diagnostics.menuRows)"))
        XCTAssertTrue(developerSource.contains("LabeledContent(row.title, value: row.value)"))
    }

    private func menuBarSource() throws -> String {
        try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/MenuBarContentView.swift"),
            encoding: .utf8
        )
    }

}
