import Foundation
import XCTest

final class SharedDefaultsAndPromptContractsTests: XCTestCase {
    func testPersistentSettingsStoresUseSharedDefaultsWrapper() throws {
        for path in [
            "Sources/AutoCompApp/Services/AutoCompDebug.swift",
            "Sources/AutoCompApp/Services/CompletionBackendConfigurationService.swift",
            "Sources/AutoCompApp/Services/EmojiPickerModels.swift",
            "Sources/AutoCompApp/Services/KeyboardShortcutSettings.swift",
            "Sources/AutoCompApp/Services/LocalProductivityMetricsStore.swift",
            "Sources/AutoCompApp/Services/MacroModels.swift",
            "Sources/AutoCompApp/Services/OverlayRecoveryAdvisor.swift",
            "Sources/AutoCompApp/Services/RemoteCompletionConsentStore.swift",
            "Sources/AutoCompCore/Stores/CompatibilitySettingsStore.swift",
            "Sources/AutoCompCore/Stores/PrivacySettingsStore.swift"
        ] {
            let source = try sourceFile(path)
            XCTAssertTrue(source.contains("MirroredUserDefaults"), "Missing shared defaults wrapper in \(path)")
            XCTAssertFalse(source.contains("private let defaults: UserDefaults"), "Direct defaults field remains in \(path)")
        }
    }

    func testCompletionProvidersReferenceSharedSystemPrompts() throws {
        let remote = try sourceFile("Sources/AutoCompCore/Services/RemoteCompletionProvider.swift")
        let apple = try sourceFile("Sources/AutoCompCore/Services/AppleFoundationCompletionProvider.swift")

        XCTAssertTrue(remote.contains("CompletionSystemPrompts.prompt(for: completionRequest.mode)"))
        XCTAssertTrue(apple.contains("instructions: CompletionSystemPrompts.continuation"))
        XCTAssertFalse(remote.contains("You are AutoComp, a low-latency autocomplete engine"))
        XCTAssertFalse(apple.contains("You are AutoComp, a low-latency autocomplete engine"))
    }
}
