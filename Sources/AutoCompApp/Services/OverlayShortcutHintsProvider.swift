import Foundation
import AutoCompCore

/// Adapts the app's keyboard shortcut settings to UI-friendly overlay hint strings.
///
/// The overlay UI should depend on this (or on `OverlayShortcutHints`) rather than
/// hardcoding labels like "Tab".
struct OverlayShortcutHintsProvider {
    private let formatter: (KeyboardShortcutKeycapFormatter.Binding) -> String

    init(formatter: @escaping (KeyboardShortcutKeycapFormatter.Binding) -> String = KeyboardShortcutKeycapFormatter.format) {
        self.formatter = formatter
    }

    func hints(from settings: KeyboardShortcutSettings) -> OverlayShortcutHints {
        OverlayShortcutHints(
            acceptNextWord: formatter(settings.acceptNextWord.keycapBinding),
            acceptFullSuggestion: formatter(settings.acceptFullSuggestion.keycapBinding),
            nextSuggestion: formatter(settings.selectNextSuggestion.keycapBinding),
            previousSuggestion: formatter(settings.selectPreviousSuggestion.keycapBinding),
            dismissSuggestion: formatter(settings.dismissSuggestion.keycapBinding)
        )
    }
}

private extension KeyboardShortcutBinding {
    var keycapBinding: KeyboardShortcutKeycapFormatter.Binding {
        KeyboardShortcutKeycapFormatter.Binding(
            keyCode: keyCode,
            modifiers: KeyboardShortcutKeycapFormatter.Modifiers(rawValue: modifiers.rawValue),
            trigger: trigger == .flagsChanged ? .flagsChanged : .keyDown
        )
    }
}
