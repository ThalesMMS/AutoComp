import AutoCompCore

/// Pure mapping for which sections of Model Settings should be shown for a given backend.
///
/// Note: This is deliberately kept in the test bundle so we can regression-test the intended
/// UX mapping without forcing the app target to expose private view-only types.
enum ModelSettingsVisibleSection: Hashable {
    case backendSelection
    case remoteConsent
    case remoteBackend
    case localModel
    case appleIntelligence
    case recommendedLocalModels
    case diagnostics
    case modelCompatibilityEvidence
    case applyChanges
    case playground
    case privacy
    case internalSuggestions
}

struct ModelSettingsVisibilityPlan: Equatable {
    var alwaysVisible: Set<ModelSettingsVisibleSection>
    var setupVisible: Set<ModelSettingsVisibleSection>
    var advancedVisible: Set<ModelSettingsVisibleSection>

    func isVisible(_ section: ModelSettingsVisibleSection, showAdvanced: Bool) -> Bool {
        if alwaysVisible.contains(section) { return true }
        if setupVisible.contains(section) { return true }
        if showAdvanced, advancedVisible.contains(section) { return true }
        return false
    }
}

extension CompletionEngineKind {
    var settingsVisibilityPlanUnderTest: ModelSettingsVisibilityPlan {
        switch self {
        case .remote:
            return ModelSettingsVisibilityPlan(
                alwaysVisible: [
                    .backendSelection,
                    .remoteConsent,
                    .remoteBackend,
                    .applyChanges
                ],
                setupVisible: [],
                advancedVisible: [
                    .modelCompatibilityEvidence,
                    .playground,
                    .diagnostics,
                    .privacy,
                    .internalSuggestions
                ]
            )
        case .localLlama:
            return ModelSettingsVisibilityPlan(
                alwaysVisible: [
                    .backendSelection,
                    .localModel,
                    .applyChanges
                ],
                setupVisible: [
                    .remoteBackend
                ],
                advancedVisible: [
                    .recommendedLocalModels,
                    .modelCompatibilityEvidence,
                    .playground,
                    .diagnostics,
                    .privacy,
                    .internalSuggestions
                ]
            )
        case .appleIntelligence:
            return ModelSettingsVisibilityPlan(
                alwaysVisible: [
                    .backendSelection,
                    .appleIntelligence,
                    .applyChanges
                ],
                setupVisible: [
                    .remoteBackend
                ],
                advancedVisible: [
                    .modelCompatibilityEvidence,
                    .playground,
                    .diagnostics,
                    .privacy,
                    .internalSuggestions
                ]
            )
        }
    }
}
