import Foundation
import XCTest

final class ShortcutsSettingsRedesignTests: XCTestCase {
    func testShortcutRowsExposeDescriptionsKeycapsRecorderAndIndividualReset() throws {
        let root = try packageRoot()
        let shortcutsSource = try source(
            root: root,
            path: "Sources/AutoCompApp/Views/Settings/Sections/ShortcutsSettingsView.swift"
        )
        let componentsSource = try source(
            root: root,
            path: "Sources/AutoCompApp/Views/Settings/Components/SettingsVisualComponents.swift"
        )

        XCTAssertTrue(shortcutsSource.contains("description: command.settingsDescription"))
        XCTAssertTrue(shortcutsSource.contains("defaultBinding: KeyboardShortcutSettings.defaults[command]"))
        XCTAssertTrue(componentsSource.contains("KeycapView(binding: binding)"))
        XCTAssertTrue(componentsSource.contains("if binding != defaultBinding"))
        XCTAssertTrue(componentsSource.contains("Image(systemName: \"arrow.counterclockwise\")"))
        XCTAssertTrue(componentsSource.contains(".accessibilityLabel(\"Reset shortcut for \\(command.title)\")"))
        XCTAssertTrue(shortcutsSource.contains("Button(isRecording ? \"Recording...\" : \"Change\")"))
    }

    func testShortcutRecorderValidatesConflictsAndReservedBindingsBeforeSaving() throws {
        let shortcutsSource = try source(
            root: try packageRoot(),
            path: "Sources/AutoCompApp/Views/Settings/Sections/ShortcutsSettingsView.swift"
        )

        XCTAssertTrue(shortcutsSource.contains("@State private var rejectedShortcut"))
        XCTAssertTrue(shortcutsSource.contains("settings.proposingUpdate(command: command, binding: binding)"))
        XCTAssertTrue(shortcutsSource.contains("case .success(let updatedSettings):"))
        XCTAssertTrue(shortcutsSource.contains("case .failure(let rejection):"))
        XCTAssertTrue(shortcutsSource.contains("already belongs to"))
        XCTAssertTrue(shortcutsSource.contains("is reserved by macOS or common app commands"))
        XCTAssertTrue(shortcutsSource.contains("return false"))
    }

    func testShortcutRecorderCancellationA11yAndMultiSuggestionRows() throws {
        let shortcutsSource = try source(
            root: try packageRoot(),
            path: "Sources/AutoCompApp/Views/Settings/Sections/ShortcutsSettingsView.swift"
        )

        XCTAssertTrue(shortcutsSource.contains("@EnvironmentObject private var engine: SuggestionEngine"))
        XCTAssertTrue(shortcutsSource.contains("if engine.isMultiSuggestionEnabled"))
        XCTAssertTrue(shortcutsSource.contains("shortcutRow(.selectPreviousSuggestion)"))
        XCTAssertTrue(shortcutsSource.contains("shortcutRow(.selectNextSuggestion)"))
        XCTAssertTrue(shortcutsSource.contains("if let recordingCommand, let preRecordingBinding"))
        XCTAssertTrue(shortcutsSource.contains("Press Escape to cancel"))
        XCTAssertTrue(shortcutsSource.contains(".accessibilityIdentifier(\"ShortcutRecorderButton.\\(command.rawValue)\")"))
        XCTAssertTrue(shortcutsSource.contains(".accessibilityIdentifier(\"ShortcutRecorderConfirmationText.\\(command.rawValue)\")"))
    }

    func testShortcutCommandDescriptionsCoverEverySettingsRow() throws {
        let source = try source(
            root: try packageRoot(),
            path: "Sources/AutoCompApp/Services/KeyboardShortcutSettings.swift"
        )

        for requiredText in [
            "Accept only the next token from the visible suggestion.",
            "Accept the full visible suggestion.",
            "Move to the previous multi-suggestion option.",
            "Move to the next multi-suggestion option.",
            "Request a suggestion without waiting for automatic activation.",
            "Hide the current suggestion and let the key pass through.",
            "Turn AutoComp on or off without changing app rules."
        ] {
            XCTAssertTrue(source.contains(requiredText), "Missing shortcut description: \(requiredText)")
        }
    }

}
