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
        let active = previewCoordinator.activeTier != .disabled
        SuggestionPipelineLog.log("presenter-show", fields: [
            "mode=\(mode.rawValue)",
            "tier=\(previewCoordinator.activeTier)",
            "active=\(active)",
            "context=\(SuggestionPipelineLog.contextDescription(context))",
            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
        ])
        setSuggestionActive(active)
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        previewCoordinator.update(suggestion, for: context, mode: mode)
        let active = previewCoordinator.activeTier != .disabled
        SuggestionPipelineLog.log("presenter-update", fields: [
            "mode=\(mode.rawValue)",
            "tier=\(previewCoordinator.activeTier)",
            "active=\(active)",
            "context=\(SuggestionPipelineLog.contextDescription(context))",
            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
        ])
        setSuggestionActive(active)
    }

    func hide() {
        previewCoordinator.hide()
        SuggestionPipelineLog.log("presenter-hide", fields: [
            "tier=\(previewCoordinator.activeTier)"
        ])
        setSuggestionActive(false)
    }
}
