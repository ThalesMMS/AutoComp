import AutoCompCore

@MainActor
final class ShortcutAwareSuggestionPresenter: SuggestionPresenter {
    private let previewCoordinator: PreviewCoordinator
    private let setSuggestionActive: (Bool) -> Void

    init(
        previewCoordinator: PreviewCoordinator,
        setSuggestionActive: @escaping (Bool) -> Void
    ) {
        self.previewCoordinator = previewCoordinator
        self.setSuggestionActive = setSuggestionActive
    }

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        previewCoordinator.show(suggestion, for: context, mode: mode)
        setSuggestionActive(previewCoordinator.activeTier != .disabled)
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        previewCoordinator.update(suggestion, for: context, mode: mode)
        setSuggestionActive(previewCoordinator.activeTier != .disabled)
    }

    func hide() {
        previewCoordinator.hide()
        setSuggestionActive(false)
    }
}
